"""Single-owner display loop. Reader, broker, database and Slack work run off-thread."""
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import logging
from queue import Empty, Queue
from threading import Thread
import time

from pymongo.errors import PyMongoError

from .data import RailsData, database_provider
from .inputs import listen_mqtt
from .ledger import Details, LedgerData
from .logs import driver_detail
from .reader import read_nfc
from .recent import RecentCheckins
from .render import VARIANT_COUNT, agenda_ready, render
from .state import Directory, EASTERN, PERSONAL_SECONDS, Screen, UTC, uid_key


LOG = logging.getLogger(__name__)


class Kiosk:
    def __init__(self, settings, rails, ledger, display, *, clock=time.monotonic,
                 wall=lambda: datetime.now(UTC)):
        self.settings, self.rails, self.ledger, self.display = settings, rails, ledger, display
        self.clock, self.wall = clock, wall
        self.events = Queue()
        self.work = ThreadPoolExecutor(3, "agenda")
        self.identity_work = ThreadPoolExecutor(2, "directory")
        self.jobs = {}
        self.screen = Screen(clock())
        self.directory = Directory()
        self.recent = RecentCheckins()
        # Subscribe before reading history when possible. A disconnected broker
        # must not prevent the startup board from showing the MongoDB seed.
        self.recent_seed_due = clock() + 5
        self.connected = self.trusted = False
        self.epoch = self.revision = 0
        self.during_load = None
        self.next_snapshot = 0
        self.waiting = defaultdict(list)
        self.sequence = self.last_accepted = 0
        self.latest_uid = self.preview_sequence = None
        self.day = wall().astimezone(EASTERN).date()
        self.drawn_generation = -1
        self.data = {}
        self.page = 0
        self.page_count = 1
        self.next_page = self.next_refresh = 0
        self.last_display_activity = self.screen.last_activity
        self.visible_visit = None
        self.next_variant = {"board": 0, "welcome": 1, "agenda": 2, "details": 3}
        self.variant = 0
        self.layout_started = self.screen.entered
        self.dimmed = False
        self.dirty = True
        self.greeting_started = None
        self.uids_after_paint = set()

    def emit(self, *event):
        self.events.put(event)

    def submit(self, name, tag, function, *args, identity=False):
        key = (name, tag)
        if key in self.jobs:
            return
        pool = self.identity_work if identity else self.work
        future = pool.submit(function, *args)
        self.jobs[key] = future
        future.add_done_callback(lambda done: self.emit("result", name, tag, done))

    def reset_directory(self, connected):
        self.epoch += 1
        self.revision += 1
        self.connected, self.trusted = connected, False
        self.during_load = None
        self.next_snapshot = 0
        self.directory = Directory()
        self.discard_scans(list(self.waiting), "identity cache reset")
        if self.screen.member:
            self.screen.show("board", self.clock())
        self.screen.pending = None

    def change(self, collection, operation, doc):
        self.revision += 1
        if collection == "cards":
            previous = self.directory.cards.get(doc["_id"])
            # A tap observed before reassignment must never greet the new
            # owner. An unknown prior UID can affect any unresolved lookup.
            if previous is None and operation != "insert":
                self.discard_scans(list(self.waiting), "card assignment changed")
            else:
                self.discard_scans([previous["uid"] if previous else None, doc.get("uid")],
                                   "card assignment changed")
        self.directory.update(collection, operation, doc)
        if self.during_load is not None:
            self.during_load[collection, doc["_id"]] = (collection, operation, doc)
        if self.trusted:
            now = self.wall()
            self.recent.resolve(self.directory, now)
            self.update_recent_board(now)
            self.screen.reconcile(self.directory, now, self.clock())
        else:
            # A direct lookup may have opened a page before the snapshot finished.
            def touches(member):
                if member is None:
                    return False
                if collection == "members":
                    return doc["_id"] == member.member_id
                return doc["_id"] == member.card_id or uid_key(doc.get("uid")) == uid_key(member.uid)
            if touches(self.screen.member):
                self.screen.show("board", self.clock())
            elif touches(self.screen.pending):
                self.screen.pending = None

    def discard_scans(self, uids, reason):
        for uid in uids:
            self.accept(None, self.waiting.pop(uid_key(uid), ()), reason)

    def accept(self, member, scans, reason="card or membership is ineligible or unknown"):
        for seq, local, at, source, record in scans:
            now = self.wall()
            if member is None or not member.valid(now):
                LOG.info("Card scan at %s, member unknown", source)
                LOG.warning("No valid member found at %s (%s)", source, reason)
                continue
            LOG.info("Card scan at %s, member %s", source, f"{member.first} {member.last}".strip())
            if record is not None:
                self.recent.add(record.with_member(member), now)
                self.update_recent_board(now)
            if seq < self.last_accepted or self.clock() - at >= PERSONAL_SECONDS:
                continue
            if self.screen.page == "welcome" and seq == self.preview_sequence:
                # This lookup belongs to the record whose large greeting was painted.
                self.screen.enrich_greeting(member)
                self.preview_sequence = None
                self.load_agenda(self.screen_tag(), member, now)
                self.next_refresh = self.clock() + 15
                continue
            self.last_accepted = seq
            self.screen.tick(at, now)
            generation = self.screen.generation
            self.screen.scan(member, local, at)
            if generation != self.screen.generation and self.screen.page == "agenda":
                self.greeting_started = at

    def resolve(self, uid):
        scans = self.waiting[uid]
        member = self.directory.lookup(uid, self.wall()) if self.trusted else None
        if member:
            del self.waiting[uid]
            self.accept(member, scans)
        else:
            self.submit("lookup", (uid, self.revision), self.rails.identity, uid, self.wall(), identity=True)

    def result(self, name, tag, future):
        if self.jobs.pop((name, tag), None) is not future or future.cancelled():
            return
        error = future.exception()
        if error:
            if name == "avatar" and not isinstance(error, PyMongoError):
                LOG.warning("Slack avatar unavailable (%s)", type(error).__name__)
            else:
                LOG.error("MongoDB %s failed: %s", name, driver_detail(error))
        value = None if error else future.result()
        if name == "snapshot":
            if tag != self.epoch or self.during_load is None:
                return
            if value is not None:
                for change in self.during_load.values():
                    value.update(*change)
                self.directory, self.trusted = value, True
                self.revision += 1
                now = self.wall()
                self.recent.resolve(value, now)
                self.update_recent_board(now)
                self.screen.reconcile(value, now, self.clock())
            self.during_load = None
            self.next_snapshot = self.clock() + (300 if value is not None else 5)
        elif name == "recent":
            now = self.wall()
            for record in value or ():
                self.recent.add(record.with_directory(self.directory) if self.trusted else record, now)
            self.update_recent_board(now)
        elif name == "lookup":
            uid, revision = tag
            if uid not in self.waiting:
                return
            if revision != self.revision:
                self.resolve(uid)
            elif error:
                self.discard_scans([uid], "MongoDB lookup failed")
            else:
                self.accept(value, self.waiting.pop(uid))
        elif tag[:2] == self.screen_tag():
            if name == "verify":
                if self.trusted:
                    return  # A completed snapshot has already revalidated this screen.
                if not value or value.member_id != self.screen.member.member_id:
                    self.screen.show("board", self.clock())
                elif value != self.screen.member:
                    self.screen.member = value
                    self.screen.generation += 1
                return
            if name == "avatar":
                details = self.data.get("details")
                if details and details.avatar == tag[2]:
                    self.data["avatar"] = value
            elif name == "details":
                old = self.data.get("details")
                details = value or Details([("Member details", [("The Ledger is temporarily unavailable.", "")])])
                if not old or details.avatar != old.avatar:
                    self.data.pop("avatar", None)
                self.data["details"] = details
                if details.avatar and not self.data.get("avatar"):
                    self.submit("avatar", (*tag, details.avatar), self.ledger.download, self.screen.member, details.avatar)
                if details == old:
                    return
            else:
                rows = value if not error else [("Temporarily unavailable", "")]
                if self.data.get(name) == rows:
                    return
                self.data[name] = rows
                if self.screen.greeting:
                    if not agenda_ready(self.data):
                        return
                    self.screen.greeting = False
            self.dirty = True

    def screen_tag(self):
        return self.screen.generation, self.screen.member.member_id if self.screen.member else None

    def update_recent_board(self, now):
        if self.screen.page == "board":
            rows = self.recent.rows(now)
            if self.data.get("recent") != rows:
                self.data["recent"] = rows
                self.dirty = True

    def scan(self, uid, local, at, source, record=None, *, after_paint=False):
        if local:
            self.last_display_activity = max(at, self.last_display_activity)
        uid = uid_key(uid)
        self.sequence += 1
        # A new card supersedes older lookups, even if it supplies no display name.
        # Consecutive local taps on the same card still run in their original order.
        if uid != self.latest_uid or after_paint:
            self.last_accepted = self.sequence
        self.latest_uid = uid
        self.preview_sequence = self.sequence if after_paint else None
        self.waiting[uid].append((self.sequence, local, at, source, record))
        if after_paint:
            self.uids_after_paint.add(uid)
        else:
            self.resolve(uid)

    def checkin(self, record, at, topic, fresh):
        now = self.wall()
        self.recent.add(record.with_directory(self.directory if self.trusted else None, live=fresh), now)
        self.update_recent_board(now)
        source = f"MQTT {topic} ({record.location})"
        timely = fresh and self.clock() - at < PERSONAL_SECONDS
        if timely:
            self.last_display_activity = max(at, self.last_display_activity)
        if not self.settings.welcomes_location(record.location):
            LOG.info("Check-in at %s, recorded name %s, time %s: welcome skipped by location filter",
                     source, record.name or "unknown", record.at.isoformat())
            return
        if not timely:
            return
        self.screen.tick(at, now)
        generation = self.screen.generation
        same_card = self.screen.member and uid_key(self.screen.member.uid) == uid_key(record.uid)
        preview = bool(record.name) and not same_card and self.screen.greet_record(record.name, at)
        if preview:
            if self.screen.generation != generation:
                self.greeting_started = at
            LOG.info("First-name welcome at %s for %s", source, self.screen.record_first)
            if not record.uid:
                # An older pending lookup cannot identify this new arrival, even for namesakes.
                self.sequence += 1
                self.last_accepted = self.sequence
                self.latest_uid = self.preview_sequence = None
        if record.uid:
            self.scan(record.uid, False, at, source, record, after_paint=preview)

    def handle(self, event):
        kind, *args = event
        if kind == "scan":
            self.scan(*args)
        elif kind == "checkin":
            self.checkin(*args)
        elif kind == "change":
            self.change(*args)
        elif kind in ("subscribed", "disconnected", "resync"):
            self.reset_directory(self.connected if kind == "resync" else kind == "subscribed")
        elif kind == "result":
            self.result(*args)

    def load_agenda(self, tag, member, now):
        self.submit("reservations", tag, self.rails.reservations, member, now)
        self.submit("events", tag, self.rails.eventbrite, now)
        self.submit("opportunities", tag, self.rails.opportunities, member, now, self.settings.opportunity_count)

    def refresh(self, now):
        tag, member = self.screen_tag(), self.screen.member
        if member and not self.trusted:
            self.submit("verify", tag, self.rails.identity, member.uid, now, identity=True)
        if self.screen.page == "agenda":
            self.load_agenda(tag, member, now)
        elif self.screen.page == "details":
            self.submit("details", tag, self.ledger.details, member, now)
        elif self.screen.page == "board":
            self.submit("leaders", tag, self.rails.leaderboard)
            self.submit("opportunities", tag, self.rails.opportunities, None, now, 10)

    def update_appearance(self, at):
        # Name-only welcomes and a verified member's loading greeting are one
        # visible layout, including when the first record gains an identity.
        view = "welcome" if self.screen.greeting else self.screen.page
        visit = (view, self.screen.visit)
        if visit != self.visible_visit or (view == "board" and
                                           at - self.layout_started >= self.settings.layout_interval_minutes * 60):
            self.visible_visit = visit
            self.variant = self.next_variant[view]
            self.next_variant[view] = (self.variant + 1) % VARIANT_COUNT
            self.layout_started = at
            self.dirty = True
        dimmed = view == "board" and at - self.last_display_activity >= self.settings.dim_after_minutes * 60
        if self.dimmed != dimmed:
            self.dimmed = dimmed
            self.dirty = True

    def paint(self, at, now):
        try:
            if self.display.probe(at):
                self.dirty = True
            output = self.display.output
            if output and self.screen.page != "sleep":
                self.update_appearance(at)
            if not output or not self.dirty:
                return
            if self.screen.page == "sleep":
                output.standby()
            else:
                image, self.page_count = render(output.size, self.screen, now, self.data, self.page,
                                                variant=self.variant, dimmed=self.dimmed,
                                                insets=self.settings.insets, stroke=self.settings.font_stroke)
                output.present(image)
                if self.greeting_started is not None and self.screen.page in ("agenda", "welcome"):
                    LOG.info("Welcome frame submitted in %.0f ms", (self.clock() - self.greeting_started) * 1000)
            self.dirty = False
            self.greeting_started = None
        except (OSError, RuntimeError, ValueError, IndexError, StopIteration) as error:
            LOG.warning("HDMI unavailable (%s); probing again", type(error).__name__)
            self.display.close()
            self.display.next_probe = at + 2

    def tick(self):
        at, now = self.clock(), self.wall()
        self.screen.tick(at, now)
        day = now.astimezone(EASTERN).date()
        if day != self.day:
            self.day = day
            self.screen.generation += 1
        if self.drawn_generation != self.screen.generation:
            for (name, tag), task in list(self.jobs.items()):
                if name not in ("snapshot", "lookup", "recent") and tag[:2] != self.screen_tag():
                    task.cancel()
            self.drawn_generation = self.screen.generation
            self.data = {}
            self.page, self.page_count, self.dirty = 0, 1, True
            self.next_page, self.next_refresh = at + 8, at
        if self.screen.page == "board" and at >= self.next_refresh:
            self.update_recent_board(now)
        if self.page_count > 1 and at >= self.next_page:
            self.page = (self.page + 1) % self.page_count
            self.dirty = True
            self.next_page = at + 8
        # Present the first-name greeting before scheduling any agenda reads.
        self.paint(at, now)
        for uid in self.uids_after_paint:
            if uid in self.waiting:
                self.resolve(uid)
        self.uids_after_paint.clear()
        if self.recent_seed_due is not None and (self.connected or at >= self.recent_seed_due):
            self.recent_seed_due = None
            self.submit("recent", (), self.rails.recent, now)
        if self.connected and self.during_load is None and at >= self.next_snapshot:
            self.during_load = {}
            self.submit("snapshot", self.epoch, self.rails.directory, identity=True)
        if at >= self.next_refresh and self.screen.page != "sleep":
            self.refresh(now)
            self.next_refresh = at + (60 if self.screen.page == "board" else 15)

    def close(self):
        self.discard_scans(list(self.waiting), "kiosk stopped before verification")
        self.work.shutdown(wait=False, cancel_futures=True)
        self.identity_work.shutdown(wait=False, cancel_futures=True)
        if self.display.output:
            try:
                self.display.output.standby()
            except (OSError, RuntimeError):
                pass
        self.display.close()


def run(settings, display, stop):
    rails = RailsData(database_provider(settings.rails_uri), settings.organizations)
    ledger = LedgerData(database_provider(settings.ledger_uri), rails, settings.excluded, settings.slack_token)
    kiosk = Kiosk(settings, rails, ledger, display)
    reader = Thread(target=read_nfc, args=(settings, kiosk.emit, stop), daemon=True, name="PN532")
    broker = Thread(target=listen_mqtt, args=(settings, kiosk.emit, stop), daemon=True, name="MQTT")
    try:
        kiosk.tick()
        reader.start()
        broker.start()
        while not stop.is_set():
            try:
                event = kiosk.events.get(timeout=0.2)
            except Empty:
                event = None
            if event:
                kiosk.handle(event)
            kiosk.tick()
    finally:
        stop.set()
        kiosk.close()
        if broker.is_alive():
            broker.join(timeout=3)
        if reader.is_alive():
            reader.join(timeout=2)

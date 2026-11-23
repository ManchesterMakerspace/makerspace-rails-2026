"""Single-owner display loop. Reader, broker, database and Slack work run off-thread."""
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import logging
from queue import Empty, Queue
from threading import Thread
import time

from .data import RailsData, database_provider
from .inputs import read_nfc, start_mqtt
from .ledger import Details, LedgerData
from .render import render
from .state import Directory, EASTERN, PERSONAL_SECONDS, Screen, UTC


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
        self.connected = self.trusted = False
        self.epoch = self.revision = 0
        self.during_load = None
        self.next_snapshot = 0
        self.waiting = defaultdict(list)
        self.sequence = self.last_accepted = 0
        self.day = wall().astimezone(EASTERN).date()
        self.drawn_generation = -1
        self.data = {}
        self.page = 0
        self.page_count = 1
        self.next_page = self.next_refresh = 0
        self.dirty = True
        self.greeting_started = None

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
        self.waiting.clear()
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
                self.waiting.clear()
            else:
                if previous:
                    self.waiting.pop(previous["uid"], None)
                self.waiting.pop(doc.get("uid"), None)
        self.directory.update(collection, operation, doc)
        if self.during_load is not None:
            self.during_load[collection, doc["_id"]] = (collection, operation, doc)
        if self.trusted:
            self.screen.reconcile(self.directory, self.wall(), self.clock())
        else:
            # A direct lookup may have opened a page before the snapshot finished.
            def touches(member):
                if member is None:
                    return False
                if collection == "members":
                    return doc["_id"] == member.member_id
                return doc["_id"] == member.card_id or doc.get("uid") == member.uid
            if touches(self.screen.member):
                self.screen.show("board", self.clock())
            elif touches(self.screen.pending):
                self.screen.pending = None

    def accept(self, member, scans):
        for seq, local, at in scans:
            if (member is None or seq <= self.last_accepted or self.clock() - at >= PERSONAL_SECONDS
                    or not member.valid(self.wall())):
                continue
            self.last_accepted = seq
            self.screen.tick(at, self.wall())
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
            # Mongo errors can include a URI, Slack errors can include a private URL.
            LOG.warning("%s temporarily unavailable (%s)", name, type(error).__name__)
        value = None if error else future.result()
        if name == "snapshot":
            if tag != self.epoch or self.during_load is None:
                return
            if value is not None:
                for change in self.during_load.values():
                    value.update(*change)
                self.directory, self.trusted = value, True
                self.revision += 1
                self.screen.reconcile(value, self.wall(), self.clock())
            self.during_load = None
            self.next_snapshot = self.clock() + (300 if value is not None else 5)
        elif name == "lookup":
            uid, revision = tag
            if uid not in self.waiting:
                return
            if revision != self.revision:
                self.resolve(uid)
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
            self.dirty = True

    def screen_tag(self):
        return self.screen.generation, self.screen.member.member_id if self.screen.member else None

    def handle(self, event):
        kind, *args = event
        if kind == "scan":
            uid, local, at = args
            self.sequence += 1
            self.waiting[uid].append((self.sequence, local, at))
            self.resolve(uid)
        elif kind == "change":
            self.change(*args)
        elif kind in ("subscribed", "disconnected", "resync"):
            self.reset_directory(self.connected if kind == "resync" else kind == "subscribed")
        elif kind == "result":
            self.result(*args)

    def refresh(self, now):
        tag, member = self.screen_tag(), self.screen.member
        if member and not self.trusted:
            self.submit("verify", tag, self.rails.identity, member.uid, now, identity=True)
        if self.screen.page == "agenda":
            self.submit("reservations", tag, self.rails.reservations, member, now)
            self.submit("events", tag, self.rails.eventbrite, now)
            self.submit("opportunities", tag, self.rails.opportunities, member, now, self.settings.opportunity_count)
        elif self.screen.page == "details":
            self.submit("details", tag, self.ledger.details, member, now)
        elif self.screen.page == "board":
            self.submit("recent", tag, self.rails.recent, now)
            self.submit("leaders", tag, self.rails.leaderboard)
            self.submit("opportunities", tag, self.rails.opportunities, None, now, 10)

    def paint(self, at, now):
        try:
            if self.display.probe(at):
                self.dirty = True
            output = self.display.output
            if not output or not self.dirty:
                return
            if self.screen.page == "sleep":
                output.standby()
            else:
                image, self.page_count = render(output.size, self.screen, now, self.data, self.page)
                output.present(image)
                if self.greeting_started is not None and self.screen.page == "agenda":
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
                if name not in ("snapshot", "lookup") and tag[:2] != self.screen_tag():
                    task.cancel()
            self.drawn_generation = self.screen.generation
            self.data = {}
            self.page, self.page_count, self.dirty = 0, 1, True
            self.next_page, self.next_refresh = at + 8, at
        if self.page_count > 1 and at >= self.next_page:
            self.page = (self.page + 1) % self.page_count
            self.dirty = True
            self.next_page = at + 8
        # Submit the welcome header before scheduling any agenda reads.
        self.paint(at, now)
        if self.connected and self.during_load is None and at >= self.next_snapshot:
            self.during_load = {}
            self.submit("snapshot", self.epoch, self.rails.directory, identity=True)
        if at >= self.next_refresh and self.screen.page != "sleep":
            self.refresh(now)
            self.next_refresh = at + (60 if self.screen.page == "board" else 15)

    def close(self):
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
    reader = Thread(target=read_nfc, args=(settings.nfc_port, kiosk.emit, stop), daemon=True, name="PN532")
    client = None
    try:
        kiosk.tick()
        reader.start()
        client = start_mqtt(settings, kiosk.emit)
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
        if client:
            client.disconnect()
            client.loop_stop()

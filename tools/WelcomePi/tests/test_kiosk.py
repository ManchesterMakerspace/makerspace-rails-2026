from concurrent.futures import Future
from datetime import datetime, timedelta
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from bson import ObjectId, json_util

from welcomepi.app import Kiosk
from welcomepi.config import Settings
from welcomepi.inputs import DoorFeed, TOPICS, start_mqtt
from welcomepi.ledger import Avatar, Details
from welcomepi.reader import CardPresence
from welcomepi.recent import Checkin
from welcomepi.state import Directory, Screen, UTC


NOW = datetime(2026, 11, 22, 15, tzinfo=UTC)


def records(first, uid, expiry=100000):
    person = {"_id": ObjectId(), "firstname": first, "status": "activeMember",
              "expirationTime": int(NOW.timestamp() + expiry) * 1000}
    card = {"_id": ObjectId(), "uid": uid, "member_id": person["_id"], "validity": "activeMember"}
    return person, card


def directory(*pairs):
    result = Directory()
    for person, card in pairs:
        result.update("members", "insert", person)
        result.update("cards", "insert", card)
    return result


class Transitions(unittest.TestCase):
    def setUp(self):
        self.pairs = [records("Mara", "01"), records("Lee", "02"), records("Jo", "03")]
        self.cache = directory(*self.pairs)
        self.mara, self.lee, self.jo = [self.cache.lookup(uid, NOW) for uid in ["01", "02", "03"]]
        self.s = Screen(0)

    def test_three_scans_with_either_initial_source_and_door_echo(self):
        for local in (True, False):
            screen = Screen(0)
            screen.scan(self.mara, local, 1)
            self.assertEqual(screen.page, "agenda")
            screen.scan(self.mara, False, 2)
            self.assertEqual(screen.page, "agenda")
            screen.scan(self.mara, True, 3)
            screen.scan(self.mara, False, 4)
            self.assertEqual(screen.page, "details")
            screen.scan(self.mara, True, 5)
            self.assertEqual((screen.page, screen.member), ("board", None))

    def test_newest_door_arrival_handoff_and_local_preemption(self):
        self.s.scan(self.mara, False, 1)
        self.s.scan(self.mara, True, 5)
        self.s.scan(self.lee, False, 20)
        self.s.scan(self.jo, False, 33)
        self.s.tick(34.99, NOW)
        self.assertEqual(self.s.member, self.mara)
        self.s.tick(35, NOW)
        self.assertEqual((self.s.page, self.s.member, self.s.last_activity), ("agenda", self.jo, 33))
        self.s.scan(self.jo, True, 40)
        self.s.scan(self.lee, False, 41)
        self.s.scan(self.mara, True, 42)
        self.assertEqual((self.s.page, self.s.member, self.s.pending), ("agenda", self.mara, None))

    def test_local_dismissal_discards_waiting_arrivals(self):
        self.s.scan(self.mara, True, 0)
        self.s.scan(self.mara, True, 2)
        self.s.scan(self.lee, False, 24)
        self.s.scan(self.mara, True, 25)
        self.s.tick(90, NOW)
        self.assertEqual((self.s.page, self.s.member, self.s.pending), ("board", None, None))

    def test_idle_cutoffs_from_last_input_and_wake(self):
        self.s.scan(self.mara, True, 7)
        self.s.tick(126.99, NOW)
        self.assertEqual(self.s.page, "agenda")
        self.s.tick(127, NOW)
        self.assertEqual(self.s.page, "board")
        self.s.tick(14406.99, NOW)
        self.assertEqual(self.s.page, "board")
        self.s.tick(14407, NOW)
        self.assertEqual(self.s.page, "sleep")
        self.s.scan(self.lee, False, 14408)
        self.assertEqual((self.s.page, self.s.member), ("agenda", self.lee))

    def test_reassignment_invalidates_pending_and_current_page(self):
        self.s.scan(self.mara, False, 1)
        self.s.scan(self.mara, True, 2)
        self.s.scan(self.lee, False, 3)
        self.cache.update("cards", "update", {**self.pairs[1][1], "member_id": self.jo.member_id})
        self.s.reconcile(self.cache, NOW, 4)
        self.assertIsNone(self.s.pending)
        self.cache.update("members", "update", {**self.pairs[0][0], "status": "suspended"})
        self.s.reconcile(self.cache, NOW, 5)
        self.assertEqual(self.s.page, "board")
        self.assertEqual(self.s.last_activity, 3)


class Inputs(unittest.TestCase):
    def test_held_tag_requires_removal_and_preserves_uid(self):
        presence = CardPresence()
        uid = bytes.fromhex("0004B103").hex().upper()
        sequence = [(uid, 1), (uid, 4), (None, 4.1), (uid, 4.2), (None, 5), (uid, 5.1)]
        self.assertEqual([presence.observe(tag, at) for tag, at in sequence], [uid, None, None, None, None, uid])

    def test_real_publisher_envelope_and_replay_guards(self):
        feed = DoorFeed()
        epoch = int(NOW.timestamp())
        doc = {"_id": ObjectId(), "uid": "00AB", "timeOf": NOW, "holder": "Unverified",
               "where": "Workshop door"}
        def msg(document=doc, published=epoch):
            return f'insert {published} {{"document": {json_util.dumps(document)} }}'.encode()
        # Retained/old records can update history without waking a screen.
        for packet, retained in ((msg(), True), (msg(published=epoch-121), False),
                                 (msg({**doc, "timeOf": epoch-121}), False)):
            self.assertFalse(feed.message("checkins/insert", packet, retained, NOW, 8)[-1])
        kind, record, at, topic, fresh = feed.message("checkins/insert", msg(), False, NOW, 8)
        self.assertEqual((kind, record.uid, record.at, record.location, at, topic, fresh),
                         ("checkin", "00AB", NOW, "Workshop door", 8, "checkins/insert", True))
        self.assertFalse(feed.message("checkins/insert", msg(), False, NOW, 9)[-1])
        self.assertEqual(feed.message("checkins/insert", msg({**doc, "_id": "other", "where": None}),
                                      False, NOW, 9)[1].location, "blank:")
        with self.assertRaises(ValueError):
            feed.message("members/update", msg(), False, NOW, 9)
        member = {"_id": ObjectId(), "firstname": "Test", "otp_secret_encrypted": "discard"}
        event = feed.message("members/insert", msg(member), False, NOW, 0)
        self.assertEqual(event[3], {"_id": member["_id"], "firstname": "Test"})
        self.assertEqual(feed.message("members/update", b'update 1 {"document": null}', False, NOW, 0), ("resync",))
        self.assertEqual(feed.message("cards/update", b'update 1 {"document": {"_id":"key"}}', False, NOW, 0), ("resync",))
        delete = f'delete {epoch} {{"document": {json_util.dumps({"_id": member["_id"]})} }}'.encode()
        self.assertEqual(feed.message("members/delete", delete, False, NOW, 9)[3], {"_id": member["_id"]})

    def test_subscribe_ack_before_trusting_cache_and_malformed_event(self):
        settings = Settings.load({"MLAB_URI": "stub", "LEDGER_URI": "stub", "MQTT_HOST": "broker"})
        emit = Mock()
        with patch("welcomepi.inputs.mqtt.Client") as factory:
            factory.return_value.loop_start.return_value = 0
            factory.return_value.subscribe.return_value = (0, 1)
            client = start_mqtt(settings, emit)
        self.assertIs(client, factory.return_value)
        client.on_connect(client, None, None, 0)
        client.subscribe.assert_called_once_with(TOPICS)
        emit.assert_not_called()
        client.on_subscribe(client, None, 1, [2] * len(TOPICS))
        emit.assert_called_once_with("subscribed")
        with self.assertLogs("welcomepi.inputs"):
            client.on_message(client, None, SimpleNamespace(topic="members/update", retain=False,
                              payload=b'update 1 {"document":{"_id":{"$oid":"oops"}}}'))
        self.assertEqual(emit.call_args.args, ("resync",))
        reader_topic = "activity/checkins/activeMember/A0B1C2"
        with self.assertLogs("welcomepi.inputs", "WARNING") as logs:
            client.on_message(client, None, SimpleNamespace(topic=reader_topic, retain=False,
                              payload=b'processed 1700000000 {"uid":"FF0001","_id":{"$oid":"invalid"}}'))
        self.assertIn(reader_topic, logs.output[0])
        self.assertNotIn("FF0001", logs.output[0])


class ManualExecutor:
    """Keep I/O in flight until the test chooses the completion order."""
    def submit(self, fn, *args):
        return Future()

    def shutdown(self, **kwargs):
        pass


class Controller(unittest.TestCase):
    def setUp(self):
        self.at = 0
        self.clock = lambda: self.at
        self.pairs = [records("Mara", "AA"), records("Lee", "BB")]
        self.cache = directory(*self.pairs)
        self.display = Mock()
        self.display.probe.return_value = False
        self.display.output.size = (800, 480)
        self.frames = []
        self.renderer = patch("welcomepi.app.render", side_effect=self.render)
        self.renderer.start()
        self.addCleanup(self.renderer.stop)
        settings = Settings.load({"MLAB_URI": "stub", "LEDGER_URI": "stub", "MQTT_HOST": "broker",
                                  "WELCOMEPI_LOCATION_PATTERNS": '["^Door A$"]'})
        self.k = Kiosk(settings, Mock(), Mock(), self.display,
                       clock=self.clock, wall=lambda: NOW + timedelta(seconds=self.at))
        self.addCleanup(self.k.close)
        self.k.work.shutdown()
        self.k.identity_work.shutdown()
        self.k.work = self.k.identity_work = ManualExecutor()
        self.k.tick()

    def render(self, size, screen, now, data, page):
        self.frames.append(SimpleNamespace(page=screen.page, member=screen.member, greeting=screen.greeting,
                                           record_first=screen.record_first, data=dict(data), jobs=list(self.k.jobs)))
        return Mock(), 1

    def finish(self, name, value=None, error=None, tag=None):
        tag = next(t for n, t in self.k.jobs if n == name) if tag is None else tag
        future = self.k.jobs[(name, tag)]
        if error:
            future.set_exception(error)
        else:
            future.set_result(value)
        while not self.k.events.empty():
            self.k.handle(self.k.events.get_nowait())
        self.k.tick()

    def scan(self, uid, local=True):
        self.at += 1
        source = "local PN532 I2C /dev/i2c-1@0x24" if local else "MQTT checkins/insert (Door A)"
        self.k.handle(("scan", uid, local, self.at, source))
        self.k.tick()

    def named_checkin(self, name, uid="", member_id=None):
        frame_count = len(self.frames)
        record = Checkin(self.k.wall(), uid=uid, name=name, location="Door A", member_id=member_id)
        self.k.handle(("checkin", record, self.at, "activity/checkins/activeMember/reader-A", True))
        self.k.tick()
        self.assertGreater(len(self.frames), frame_count, "The first-name greeting was not displayed")
        return self.frames[frame_count]

    def test_audit_each_scan_with_verified_full_name_and_reader(self):
        self.pairs[0][0]["lastname"] = "Example"
        self.preload()
        with self.assertLogs("welcomepi.app", level="INFO") as log:
            self.scan("AA")
            self.scan("AA", False)
            self.scan("UNKNOWN")
            self.finish("lookup", None)
        info = [r.getMessage() for r in log.records if r.levelname == "INFO" and "Card scan" in r.getMessage()]
        self.assertEqual(info, ["Card scan at local PN532 I2C /dev/i2c-1@0x24, member Mara Example",
                                "Card scan at MQTT checkins/insert (Door A), member Mara Example",
                                "Card scan at local PN532 I2C /dev/i2c-1@0x24, member unknown"])
        warnings = [r.getMessage() for r in log.records if r.levelname == "WARNING"]
        self.assertEqual(len(warnings), 1)
        self.assertIn("No valid member found at local PN532 I2C", warnings[0])
        self.assertNotIn("UNKNOWN", str(log.output))

    def test_pending_scans_each_logged_once_on_reassignment_or_database_timeout(self):
        from pymongo.errors import ServerSelectionTimeoutError
        with self.assertLogs("welcomepi.app", level="INFO") as log:
            self.scan("AA")
            self.scan("AA", False)
            old_tag = next(t for n, t in self.k.jobs if n == "lookup")
            self.k.handle(("change", "cards", "update", self.pairs[0][1]))
            self.finish("lookup", self.cache.lookup("AA", NOW), tag=old_tag)
            self.scan("BB")
            self.finish("lookup", error=ServerSelectionTimeoutError("test-db:27017 timed out"))
        self.assertEqual(sum(r.getMessage().startswith("Card scan") for r in log.records), 3)
        self.assertEqual(sum(r.levelname == "WARNING" for r in log.records), 3)
        self.assertIn("MongoDB lookup failed: ServerSelectionTimeoutError: test-db:27017 timed out",
                      next(r.getMessage() for r in log.records if r.levelname == "ERROR"))
        self.assertNotIn("Mara", str(log.output))

    def preload(self):
        self.k.handle(("subscribed",))
        self.k.tick()
        self.finish("snapshot", self.cache)

    def test_snapshot_race_and_reconnect(self):
        self.k.handle(("subscribed",))
        self.k.tick()
        person, card = self.pairs[0]
        self.k.handle(("change", "cards", "update", {**card, "uid": "00FF"}))
        self.k.handle(("change", "members", "delete", {"_id": self.pairs[1][0]["_id"]}))
        self.finish("snapshot", self.cache)
        self.assertIsNone(self.k.directory.lookup("AA", NOW))
        self.assertIsNone(self.k.directory.lookup("BB", NOW))
        self.scan("00FF")
        self.assertEqual(self.k.screen.member.member_id, person["_id"])
        self.k.handle(("disconnected",))
        self.k.tick()
        self.assertFalse(self.k.trusted)
        self.assertEqual(self.k.screen.page, "board")
        self.scan("00FF")
        with self.assertLogs("welcomepi.app"):
            self.finish("lookup", error=ConnectionError())
        self.assertEqual(self.k.screen.page, "board")
        self.k.handle(("subscribed",))
        self.k.tick()
        self.finish("snapshot", directory(*self.pairs))
        self.scan("AA")
        self.assertEqual(self.k.screen.page, "agenda")

    def test_first_frame_before_agenda_io_and_old_avatar_discarded(self):
        self.preload()
        self.scan("AA", False)
        frame = self.frames[-1]
        self.assertEqual((frame.page, frame.member.first, frame.data), ("agenda", "Mara", {}))
        self.assertTrue(frame.greeting)
        self.assertFalse(any(n == "reservations" for n, _ in frame.jobs))
        self.finish("reservations", [("Lathe", "4:00 PM")])
        self.assertFalse(self.frames[-1].greeting)
        self.assertEqual(set(self.frames[-1].data), {"reservations"})
        self.scan("AA")
        self.assertFalse(self.frames[-1].greeting)
        ref = Avatar("F1", "rev", "")
        self.finish("details", Details([], 2, ref))
        avatar_tag = next(t for n, t in self.k.jobs if n == "avatar")
        self.k.jobs[("avatar", avatar_tag)].set_running_or_notify_cancel()
        self.scan("BB")
        self.finish("avatar", object(), tag=avatar_tag)
        self.assertNotIn("avatar", self.k.data)
        self.assertEqual(self.k.screen.member.first, "Lee")
        self.assertTrue(self.frames[-1].greeting)

    def test_empty_agenda_finishes_greeting_without_replaying_it_on_member_refresh(self):
        self.preload()
        self.scan("BB", False)
        first_frame = self.frames[-1]
        self.finish("events", [])
        self.finish("opportunities", [])
        self.assertIs(self.frames[-1], first_frame)
        self.assertTrue(first_frame.greeting)
        self.finish("reservations", [])
        self.assertFalse(self.frames[-1].greeting)

        updated = {**self.pairs[1][0], "firstname": "Leigh"}
        self.k.handle(("change", "members", "update", updated))
        self.k.tick()
        self.assertEqual(self.frames[-1].member.first, "Leigh")
        self.assertFalse(self.frames[-1].greeting)

    def test_late_uncached_lookup_does_not_replace_newer_member(self):
        self.preload()
        self.scan("not-in-cache")
        self.scan("BB")
        self.finish("lookup", self.cache.lookup("AA", NOW))
        self.assertEqual(self.k.screen.member.first, "Lee")

    def test_old_tap_cannot_open_new_card_owners_page(self):
        self.scan("AA")
        old_lookup = next(t for n, t in self.k.jobs if n == "lookup")
        changed = {**self.pairs[0][1], "member_id": self.pairs[1][0]["_id"]}
        self.k.handle(("change", "cards", "update", changed))
        new_owner = directory((self.pairs[1][0], changed)).lookup("AA", NOW)
        self.finish("lookup", new_owner, tag=old_lookup)
        self.assertEqual(self.k.screen.page, "board")
        self.scan("AA")
        self.finish("lookup", new_owner)
        self.assertEqual(self.k.screen.member.first, "Lee")

    def test_current_snapshot_supersedes_inflight_direct_verification(self):
        self.k.handle(("subscribed",))
        self.k.tick()
        self.scan("AA")
        self.finish("lookup", self.cache.lookup("AA", NOW))
        self.finish("snapshot", self.cache)
        with self.assertLogs("welcomepi.app"):
            self.finish("verify", error=ConnectionError())
        self.assertTrue(self.k.trusted)
        self.assertEqual(self.k.screen.member.first, "Mara")

    def test_day_rollover_while_board_visible(self):
        first = self.k.screen_tag()
        self.at = (datetime(2026, 11, 23, 5, tzinfo=UTC) - NOW).total_seconds()
        self.k.screen.last_activity = self.at - 300
        self.k.tick()
        self.assertNotEqual(first, self.k.screen_tag())
        self.assertIn(("leaders", self.k.screen_tag()), self.k.jobs)

    def test_location_filter_logs_activity_and_updates_board_without_welcoming(self):
        self.preload()
        self.scan("AA")  # Local taps do not go into the recent door history.
        old_activity = self.k.screen.last_activity
        self.at += 10
        now = self.k.wall()
        stamp = int(now.timestamp())
        activity = DoorFeed()
        payload = f'welcome {stamp} {{"document": {{"_id": {stamp}, "name": "Lee", "uid": "BB", "reader": "Side door"}}}}'
        refused = activity.message("activity/checkins/activeMember/side-reader", payload.encode(), False, now, self.at)
        with self.assertLogs("welcomepi.app", "INFO") as messages:
            self.k.handle(refused)
            self.k.tick()
        self.assertIn("Side door", messages.output[0])
        self.assertIn("side-reader", messages.output[0])
        self.assertNotIn("BB", messages.output[0])
        self.assertIn("location", messages.output[0])
        self.assertEqual((self.k.screen.member.first, self.k.screen.last_activity), ("Mara", old_activity))
        self.assertEqual([name for name, _ in self.k.recent.rows(now)], ["Lee"])

        self.k.screen.show("board", self.at)
        self.k.tick()
        self.assertEqual(self.frames[-1].data["recent"], self.k.recent.rows(now))
        self.at += 2
        now = self.k.wall()
        stamp = int(now.timestamp())
        payload = f'processed {stamp} {{"document": {{"_id":{stamp},"uid":"BB","time":{stamp},"where":"DOOR a","reader":"Side door"}}}}'
        self.k.handle(activity.message("activity/checkins/BB", payload.encode(), False, now, self.at))
        self.k.tick()
        self.assertEqual((self.k.screen.page, self.k.screen.member.first), ("agenda", "Lee"))
        self.assertEqual(len(self.k.recent.rows(now)), 1)

    def test_topic_reader_is_logged_but_does_not_supply_a_missing_location(self):
        self.preload()
        stamp = int(NOW.timestamp())
        payload = f'welcome {stamp} {{"document": {{"_id": {stamp}, "name": "River"}}}}'
        event = DoorFeed().message("activity/checkins/Door A", payload.encode(), False, NOW, self.at)
        with self.assertLogs("welcomepi.app", "INFO") as log:
            self.k.handle(event)
        self.k.tick()
        self.assertIn("activity/checkins/Door A (blank:)", log.output[0])
        self.assertEqual((self.k.screen.page, self.k.data["recent"]), ("board", [("River", "10:00 AM")]))

    def test_name_only_welcome_then_document_uid_on_another_feed(self):
        self.preload()
        now = self.k.wall()
        stamp = int(now.timestamp())
        feed = DoorFeed()
        brief = f'welcome {stamp} {{"document": {{"_id": {stamp}, "name": "Lee", "where": "Door A"}}}}'
        # The last topic segment happens to match another member's card.
        frame_count = len(self.frames)
        self.k.handle(feed.message("activity/checkins/activeMember/AA", brief.encode(), False, now, self.at))
        self.k.tick()
        first = self.frames[frame_count]
        self.assertEqual((first.page, first.record_first, first.member), ("welcome", "Lee", None))
        full = f'insert {stamp} {{_id: 123, uid: "BB", holder: "Lee Example", where: "Door A", time: {stamp}}}'
        self.k.handle(feed.message("checkins/insert", full.encode(), False, now, self.at))
        self.k.tick()
        self.assertEqual((self.k.screen.page, self.k.screen.member.uid), ("agenda", "BB"))
        self.assertEqual(self.k.recent.rows(now), [("Lee", "10:00 AM")])

    def test_uid_selects_its_owner_even_when_a_namesakes_full_name_is_in_the_record(self):
        self.pairs[0][0].update(firstname="Lee", lastname="Brook")
        self.pairs[1][0]["lastname"] = "Lake"
        self.preload()
        first = self.named_checkin("Lee Brook", "BB")
        self.assertEqual((first.page, first.record_first, first.member, first.data), ("welcome", "Lee", None, {}))
        self.assertFalse(any(name in ("lookup", "reservations", "details") for name, _ in first.jobs))
        self.k.tick()
        member = self.k.screen.member
        self.assertEqual((self.k.screen.page, member.member_id, member.last),
                         ("agenda", self.pairs[1][0]["_id"], "Lake"))
        self.assertFalse(any(name == "lookup" for name, _ in self.k.jobs))
        rows = [("Wood shop", "3:00 PM")]
        self.finish("reservations", rows)
        self.assertEqual((self.frames[-1].greeting, self.frames[-1].data["reservations"]), (False, rows))
        self.scan("BB")
        self.assertEqual((self.k.screen.page, self.k.screen.member.uid), ("details", "BB"))

    def test_cold_uid_lookup_starts_after_first_frame_and_uses_card_instead_of_recorded_name(self):
        with patch.object(self.k, "submit", wraps=self.k.submit) as submit:
            first = self.named_checkin("Mara", "bb")
            self.assertEqual((first.page, first.record_first, first.member), ("welcome", "Mara", None))
            self.assertFalse(any(name in ("lookup", "reservations") for name, _ in first.jobs))
            self.k.tick()
            lookup, = [c for c in submit.call_args_list if c.args[0] == "lookup"]
            self.assertEqual(lookup.args[2:4], (self.k.rails.identity, "BB"))
        self.finish("lookup", self.cache.lookup("BB", NOW))
        self.k.tick()
        self.assertEqual(self.k.screen.member.member_id, self.pairs[1][0]["_id"])
        rows = [("Assembly bench", "9:00 AM")]
        self.finish("reservations", rows)
        frame = self.frames[-1]
        self.assertEqual((frame.page, frame.member.first, frame.greeting, frame.data["reservations"]),
                         ("agenda", "Lee", False, rows))

    def test_missing_uid_keeps_greeting_public_even_with_a_unique_cached_name_and_member_id(self):
        self.preload()
        first = self.named_checkin("Mara", member_id=self.pairs[0][0]["_id"])
        self.assertEqual(first.record_first, "Mara")
        self.k.tick()
        self.assertEqual((self.k.screen.page, self.k.screen.member), ("welcome", None))
        self.assertFalse(any(name in ("lookup", "reservations", "details") for name, _ in self.k.jobs))
        self.scan("AA")
        self.assertEqual((self.k.screen.page, self.k.screen.member.uid), ("agenda", "AA"))

    def test_ineligible_or_unknown_card_keeps_private_data_off_the_screen(self):
        self.pairs[0][1]["validity"] = "revoked"
        self.preload()
        for uid, name in (("AA", "Lee"), ("UNKNOWN", "Mara")):
            with self.subTest(uid=uid):
                self.at += 1
                self.named_checkin(name, uid)
                self.k.tick()
                with self.assertLogs("welcomepi.app", level="WARNING"):
                    self.finish("lookup", None)
                self.assertIsNone(self.k.screen.member)
                self.assertFalse(any(name in ("reservations", "details") for name, _ in self.k.jobs))

    def test_late_card_lookup_cannot_replace_a_newer_name_only_arrival_at_the_same_door(self):
        self.named_checkin("Lee", "BB")
        self.k.tick()
        old = next(tag for name, tag in self.k.jobs if name == "lookup")
        self.k.jobs["lookup", old].set_running_or_notify_cancel()
        self.at += 1
        self.k.handle(("checkin", Checkin(self.k.wall(), name="Lee", location="Door A"),
                       self.at, "activity/checkins/activeMember/reader-A", True))
        self.k.tick()
        self.finish("lookup", self.cache.lookup("BB", NOW), tag=old)
        self.assertEqual((self.k.screen.page, self.k.screen.record_first, self.k.screen.member), ("welcome", "Lee", None))
        self.assertFalse(any(name in ("reservations", "details") for name, _ in self.k.jobs))

    def test_earlier_card_lookup_cannot_open_an_agenda_while_a_newer_uid_only_record_waits(self):
        self.named_checkin("Mara", "AA")
        old = next(tag for name, tag in self.k.jobs if name == "lookup" and tag[0] == "AA")
        self.at += 1
        self.k.handle(("checkin", Checkin(self.k.wall(), uid="BB", location="Door A"),
                       self.at, "activity/checkins/activeMember/reader-A", True))
        self.k.tick()
        new = next(tag for name, tag in self.k.jobs if name == "lookup" and tag[0] == "BB")
        self.finish("lookup", self.cache.lookup("AA", NOW), tag=old)
        self.assertIsNone(self.k.screen.member)
        self.assertFalse(any(name == "reservations" for name, _ in self.k.jobs))
        self.finish("lookup", self.cache.lookup("BB", NOW), tag=new)
        self.assertEqual((self.k.screen.page, self.k.screen.member.first, self.k.screen.member.uid), ("agenda", "Lee", "BB"))

    def test_cached_agenda_survives_a_namesake_and_closes_on_card_revocation(self):
        self.preload()
        self.named_checkin("Mara", "AA")
        self.k.tick()
        self.finish("reservations", [("Laser", "3:00 PM")])
        self.k.handle(("change", "members", "insert", records("Mara", "CC")[0]))
        self.k.tick()
        self.assertEqual(self.k.screen.member.member_id, self.pairs[0][0]["_id"])
        self.k.handle(("change", "cards", "update", {**self.pairs[0][1], "validity": "revoked"}))
        self.k.tick()
        self.assertEqual((self.frames[-1].page, self.k.screen.member), ("board", None))
        self.assertNotIn("reservations", self.frames[-1].data)

    def test_live_records_with_different_labels_update_one_history_entry_by_card(self):
        self.preload()
        self.named_checkin("Outdated Holder", "BB", member_id=self.pairs[0][0]["_id"])
        self.at += 10
        latest = Checkin(self.k.wall(), uid="bb", name="Another Label", location="Side door")
        self.k.handle(("checkin", latest, self.at, "activity/checkins/reader-B", True))
        self.k.tick()
        arrival, = self.k.recent.entries
        self.assertEqual((arrival.member_id, arrival.name, arrival.at),
                         (self.pairs[1][0]["_id"], "Lee", self.k.wall()))

    def test_name_only_welcome_times_out_and_preserves_private_details(self):
        self.preload()
        record = Checkin(NOW, name="River Example", location="Door A")
        self.k.handle(("checkin", record, self.at, "activity/checkins/#", True))
        self.k.tick()
        self.assertEqual(self.k.screen.record_first, "River")
        self.at += 120
        self.k.tick()
        self.assertEqual(self.k.screen.page, "board")
        self.scan("AA")
        self.scan("AA")
        self.k.handle(("checkin", record, self.at, "activity/checkins/#", True))
        self.k.tick()
        self.assertEqual((self.k.screen.page, self.k.screen.member.first), ("details", "Mara"))

    def test_startup_seed_merges_with_mqtt_and_board_refreshes_from_memory(self):
        with patch.object(self.k, "submit", wraps=self.k.submit) as submit:
            self.preload()
            old = Checkin(NOW - timedelta(hours=1), uid="AA", name="Mara", location="Door A")
            live = Checkin(NOW, uid="AA", name="Mara", location="Door A")
            self.k.handle(("checkin", live, self.at, "checkins/insert", True))
            self.k.tick()
            self.assertEqual(self.k.screen.page, "agenda")
            self.finish("recent", [old, Checkin(NOW - timedelta(hours=15), uid="BB", name="Lee")])
            self.k.handle(("disconnected",))
            self.k.tick()
            self.assertEqual(self.k.data["recent"], [("Mara", "10:00 AM"), ("Lee", "7:00 PM")])
            self.k.handle(("subscribed",))
            self.at = 14 * 3600  # Midnight in Manchester.
            self.k.screen.last_activity = self.at - 300
            self.k.tick()
            self.assertEqual(self.k.data["recent"], [("Mara", "10:00 AM")])
            self.at += 2 * 3600 + 61
            self.k.screen.last_activity = self.at - 300
            self.k.tick()
            self.assertEqual(self.k.data["recent"], [])
            self.assertEqual(sum(c.args[0] == "recent" for c in submit.call_args_list), 1)

    def test_broker_offline_during_startup_still_seeds_once_and_accepts_history_after_failure(self):
        self.at = 6
        self.k.tick()
        with self.assertLogs("welcomepi.app", "ERROR"):
            self.finish("recent", error=ConnectionError("seed unavailable"))
        self.at += 60
        self.k.tick()
        self.assertFalse(any(name == "recent" for name, tag in self.k.jobs))
        history = Checkin(NOW - timedelta(hours=2), uid="BB", name="Lee", location="Door A")
        self.k.handle(("checkin", history, self.at, "checkins/insert", False))
        self.k.tick()
        self.assertEqual((self.k.screen.page, self.k.data["recent"]), ("board", [("Lee", "8:00 AM")]))

    def test_ledger_failure_is_visible_only_on_requested_page(self):
        self.preload()
        self.scan("AA")
        self.scan("AA")
        with self.assertLogs("welcomepi.app"):
            self.finish("details", error=ConnectionError())
        self.assertIn("temporarily unavailable", self.k.data["details"].sections[0][1][0][0])
        self.scan("AA")
        self.assertEqual((self.k.screen.page, self.k.data), ("board", {"recent": []}))

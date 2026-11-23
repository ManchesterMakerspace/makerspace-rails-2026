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
        self.assertIsNone(feed.message("checkins/insert", msg(), True, NOW, 8))
        self.assertIsNone(feed.message("checkins/insert", msg(published=epoch-121), False, NOW, 8))
        self.assertIsNone(feed.message("checkins/insert", msg({**doc, "timeOf": epoch-121}), False, NOW, 8))
        self.assertEqual(feed.message("checkins/insert", msg(), False, NOW, 8),
                         ("scan", "00AB", False, 8, "MQTT checkins/insert (Workshop door)"))
        self.assertIsNone(feed.message("checkins/insert", msg(), False, NOW, 9))
        self.assertEqual(feed.message("checkins/insert", msg({**doc, "_id": "other", "where": None}),
                                      False, NOW, 9)[-1], "MQTT checkins/insert")
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
        self.k = Kiosk(SimpleNamespace(opportunity_count=5), Mock(), Mock(), self.display,
                       clock=self.clock, wall=lambda: NOW + timedelta(seconds=self.at))
        self.addCleanup(self.k.close)
        self.k.work.shutdown()
        self.k.identity_work.shutdown()
        self.k.work = self.k.identity_work = ManualExecutor()
        self.k.tick()

    def render(self, size, screen, now, data, page):
        self.frames.append((screen.page, screen.member, dict(data), list(self.k.jobs)))
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
        page, member, data, jobs = self.frames[-1]
        self.assertEqual((page, member.first, data), ("agenda", "Mara", {}))
        self.assertFalse(any(n == "reservations" for n, _ in jobs))
        self.scan("AA")
        ref = Avatar("F1", "rev", "")
        self.finish("details", Details([], 2, ref))
        avatar_tag = next(t for n, t in self.k.jobs if n == "avatar")
        self.k.jobs[("avatar", avatar_tag)].set_running_or_notify_cancel()
        self.scan("BB")
        self.finish("avatar", object(), tag=avatar_tag)
        self.assertNotIn("avatar", self.k.data)
        self.assertEqual(self.k.screen.member.first, "Lee")

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
        self.assertIn(("recent", self.k.screen_tag()), self.k.jobs)

    def test_ledger_failure_is_visible_only_on_requested_page(self):
        self.preload()
        self.scan("AA")
        self.scan("AA")
        with self.assertLogs("welcomepi.app"):
            self.finish("details", error=ConnectionError())
        self.assertIn("temporarily unavailable", self.k.data["details"].sections[0][1][0][0])
        self.scan("AA")
        self.assertEqual((self.k.screen.page, self.k.data), ("board", {}))

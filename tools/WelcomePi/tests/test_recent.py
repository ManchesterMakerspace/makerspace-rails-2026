from dataclasses import replace
from datetime import datetime, timedelta
import unittest

from welcomepi.inputs import DoorFeed
from welcomepi.recent import Checkin, RecentCheckins
from welcomepi.state import Directory, UTC


NOW = datetime(2026, 11, 24, 12, tzinfo=UTC)


class RecentArrivals(unittest.TestCase):
    def test_out_of_order_seed_merges_with_live_arrival_and_expires_without_io(self):
        cache = RecentCheckins()
        live = Checkin(NOW, "00aF", "Dana", "door")
        cache.add(live, NOW)
        for n in range(1, 15):
            cache.add(Checkin(NOW - timedelta(minutes=n), str(n), f"Guest{n}"), NOW)
        cache.add(replace(live, uid="00AF", at=NOW - timedelta(hours=1), name="Dana Lee", member_id="d"), NOW)
        first, *rest = cache.entries
        self.assertEqual((first.member_id, first.at, first.location, first.name), ("d", NOW, "door", "Dana Lee"))
        self.assertEqual(len(rest), 9)
        self.assertEqual(cache.rows(NOW), [("Dana", "7:00 AM"), ("Guest1", "6:59 AM"), ("Guest2", "6:58 AM"),
                                           ("Guest3", "6:57 AM"), ("Guest4", "6:56 AM")])
        self.assertEqual(cache.rows(NOW + timedelta(hours=16)), [("Dana", "7:00 AM")])
        self.assertEqual(cache.rows(NOW + timedelta(hours=16, seconds=1)), [])

    def test_namesakes_and_a_reassigned_card_remain_distinct(self):
        cache, directory = RecentCheckins(), Directory()
        for uid, ident, last in (("AA", "a", "Xu"), ("BB", "b", "Barr")):
            directory.update("members", "insert", {"_id": ident, "firstname": "Alex", "lastname": last})
            directory.update("cards", "insert", {"_id": uid, "uid": uid, "member_id": ident})
            cache.add(Checkin(NOW, uid, "Alex"), NOW)
        self.assertEqual(len(cache.entries), 2)
        cache.resolve(directory, NOW)
        self.assertEqual({r.member_id for r in cache.entries}, {"a", "b"})
        directory.update("cards", "update", {"_id": "AA", "uid": "AA", "member_id": "b"})
        cache.resolve(directory, NOW)
        cache.add(Checkin(NOW, "AA", "Alex Barr").with_directory(directory), NOW)
        self.assertEqual({r.member_id for r in cache.entries}, {"a", "b"})
        past_owner = Checkin(NOW, "aa", "Alex Xu").with_directory(directory)
        self.assertIsNone(past_owner.member_id)

    def test_identity_lookup_collapses_new_card_and_previous_member_visit(self):
        cache = RecentCheckins()
        cache.add(Checkin(NOW - timedelta(minutes=5), "BB", "Robin Demo", member_id="r"), NOW)
        arrival = Checkin(NOW, "AA", "Robin")
        cache.add(arrival, NOW)  # MQTT arrived during a directory reload.
        cache.add(replace(arrival, member_id="r"), NOW)
        self.assertEqual(cache.entries, [replace(arrival, name="Robin Demo", member_id="r")])

    def test_cold_live_uid_collapses_different_holder_labels_and_preserves_an_old_visit(self):
        cache, directory = RecentCheckins(), Directory()
        previous = Checkin(NOW - timedelta(hours=1), "00BB", "Former Holder", member_id="previous")
        cache.add(previous, NOW)
        first = Checkin(NOW - timedelta(seconds=15), "00BB", "Alias One")
        second = Checkin(NOW, "00bb", "Correct Outdated")
        for live in (first, second):
            cache.add(live.with_directory(None, live=True), NOW)
        self.assertEqual(len(cache.entries), 2)
        directory.update("members", "insert", {"_id": "current", "firstname": "Correct"})
        directory.update("cards", "insert", {"_id": "card", "uid": "00BB", "member_id": "current"})
        cache.resolve(directory, NOW)
        cache.add(second.with_directory(None, live=True), NOW)
        self.assertEqual(cache.entries, [replace(second, name="Correct", member_id="current"), previous])

    def test_welcome_and_full_record_with_different_topic_suffix_and_body_uid(self):
        epoch = int(NOW.timestamp())
        welcome = (f'welcome {epoch} {{"document":{{"_id":{epoch},'
                   '"name":"Robin","where":"North"}}')
        processed = (f'processed {epoch} {{"document":{{"_id":{epoch - 3},'
                     f'"time":{(epoch - 3) * 1000},"uid":"0022","holder":"Robin  Demo ","where":"North"}}}}')
        feed = DoorFeed()
        short = feed.message("activity/checkins/activeMember/00FA", welcome.encode(), False, NOW, 0)[1]
        full = feed.message("activity/checkins/00FB", processed.encode(), False, NOW, 1)[1]
        self.assertEqual(short.uid, "")
        for deliveries in ((short, full), (full, short)):
            with self.subTest(deliveries=deliveries):
                cache = RecentCheckins()
                for record in deliveries:
                    cache.add(record, NOW)
                self.assertEqual(cache.entries, [Checkin(NOW, "0022", "Robin Demo", "North")])

    def test_first_name_welcome_does_not_change_another_members_visit(self):
        cache = RecentCheckins()
        namesake = Checkin(NOW - timedelta(hours=1), "AA", "Dana Lee", "Entry", member_id="a")
        previous = Checkin(NOW - timedelta(minutes=40), "BB", "Dana Park", "Entry", member_id="b")
        for entry in (namesake, previous, Checkin(NOW, name="Dana", location="Entry")):
            cache.add(entry, NOW)
        cache.add(replace(previous, at=NOW - timedelta(seconds=1)), NOW)
        self.assertEqual(cache.entries, [replace(previous, at=NOW), namesake])

        # A first-name-only copy cannot distinguish two Danas at this door.
        cache.add(replace(namesake, at=NOW), NOW)
        cache.add(Checkin(NOW, name="Dana", location="Entry"), NOW)
        self.assertEqual({entry.member_id for entry in cache.entries}, {"a", "b"})

    def test_name_fallback_uses_normalized_whole_name_when_uid_is_missing(self):
        cache = RecentCheckins()
        first = Checkin.from_document({"holder": " Dana  Lee ", "reader": "south"}, NOW)
        second = Checkin.from_document({"name": "dana lee", "where": "north", "reader": "ignored"}, NOW)
        cache.add(first, NOW)
        cache.add(second, NOW)
        self.assertEqual(len(cache.entries), 1)
        self.assertEqual((first.location, second.location), ("south", "north"))
        self.assertEqual(Checkin.from_document({}, NOW).location, "blank:")
        cache.add(Checkin(NOW, "AA", "Dana Lee"), NOW)
        cache.add(Checkin(NOW, "BB", "Dana Kerr"), NOW)
        self.assertEqual(len(cache.entries), 2)

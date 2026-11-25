from dataclasses import replace
from datetime import datetime, timedelta
import os
from unittest import TestCase
from uuid import uuid4

from bson import ObjectId
import mongomock
from pymongo import MongoClient

from welcomepi.data import RailsData
from welcomepi.ledger import LedgerData
from welcomepi.state import EASTERN, UTC, day_bounds


class Reads(TestCase):
    def setUp(self):
        port = os.environ.get("WELCOMEPI_TEST_MONGO_PORT")
        if port:
            client = MongoClient("127.0.0.1", int(port), tz_aware=True, serverSelectionTimeoutMS=3000)
            self.addCleanup(client.close)
        else:
            client = mongomock.MongoClient(tz_aware=True)
        prefix = "welcomepi_test_" + uuid4().hex
        self.db, self.ledger_db = client[prefix], client[prefix + "_ledger"]
        if port:
            self.addCleanup(client.drop_database, self.db.name)
            self.addCleanup(client.drop_database, self.ledger_db.name)
        self.source = RailsData(lambda: self.db, ["space"])
        self.ledger = LedgerData(lambda: self.ledger_db, self.source, {"U999"}, "")
        self.now = datetime(2026, 11, 23, 3, tzinfo=UTC)  # Sunday 10 pm in Manchester
        self.today = datetime(2026, 11, 22, tzinfo=UTC)  # Mongoid Date
        self.id = ObjectId()
        self.uid = "0004B0"
        self.db.members.insert_one({"_id": self.id, "firstname": "Robin", "lastname": "Demo",
                                    "status": "activeMember", "expirationTime": int(self.now.timestamp() + 86400) * 1000})
        self.db.cards.insert_one({"uid": self.uid, "validity": "activeMember", "member_id": self.id})
        self.member = self.source.identity(self.uid, self.now)

    def test_exact_unique_card_and_unexpired_unmerged_member(self):
        self.assertEqual(self.member, self.source.directory().lookup(self.uid, self.now))
        self.assertEqual(self.member, self.source.directory().lookup(self.uid.lower(), self.now))
        self.assertEqual(self.member, self.source.identity(self.uid.lower(), self.now))
        self.assertIsNone(self.source.identity("04B0", self.now))
        self.assertEqual(self.source.scan_identity("04B0", self.now), (None, False))
        self.assertEqual(self.source.scan_identity(self.uid, self.now + timedelta(days=1)), (None, True))
        self.assertIsNone(self.source.identity(self.uid, self.now + timedelta(days=1)))
        self.db.members.update_one({"_id": self.id}, {"$set": {"merged_at": self.now}})
        self.assertIsNone(self.source.identity(self.uid, self.now))
        self.db.members.update_one({"_id": self.id}, {"$unset": {"merged_at": ""}})
        self.db.cards.insert_one({"uid": self.uid.lower(), "validity": "lost"})
        self.assertIsNone(self.source.identity(self.uid, self.now))
        self.assertIsNone(self.source.directory().lookup(self.uid, self.now))

    def test_card_uid_selects_the_assigned_member_even_with_identical_names(self):
        other_id = ObjectId()
        self.db.members.insert_one({"_id": other_id, "firstname": "Robin", "lastname": "Demo",
                                    "status": "activeMember", "expirationTime": self.member.expires_ms})
        self.db.cards.insert_one({"uid": "0004A0", "member_id": other_id, "validity": "activeMember"})
        directory = self.source.directory()
        for lookup in (directory.lookup, self.source.identity):
            self.assertEqual(lookup("0004A0", self.now).member_id, other_id)
            self.assertEqual(lookup(self.uid, self.now).member_id, self.id)
            for missing in (None, "", "Robin Demo"):
                self.assertIsNone(lookup(missing, self.now))

    def test_held_reservations_overlap_half_open_window(self):
        shop = self.db.shops.insert_one({"name": "Wood"}).inserted_id
        tool = self.db.tools.insert_one({"name": "Lathe"}).inserted_id
        def book(start, end, status, member=None):
            self.db.reservations.insert_one({"member_id": member or self.id, "status": status,
                "shop_id": shop, "tool_ids": [str(tool)], "start_at": self.now + timedelta(hours=start),
                "end_at": self.now + timedelta(hours=end)})
        for args in [(-1, 0, "approved"), (-1, 1, "pending"), (1, 3, "unpaid"), (11, 14, "approved"),
                     (12, 15, "approved"), (2, 3, "denied"), (2, 3, "cancelled"), (2, 3, "approved", ObjectId())]:
            book(*args)
        rows = self.source.reservations(self.member, self.now)
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0][0], "Wood · Lathe")
        self.assertIn("Pending", rows[0][1])
        self.assertIn("Mon 1:00 AM · Unpaid", rows[1][1])
        self.assertIn("Mon 9:00 AM", rows[2][1])

    def test_valid_checkouts_grace_through_eastern_day(self):
        for name, fields in [("Lathe", {"expires_on": self.today}), ("Saw", {}),
                             ("Mill", {"expires_on": self.today - timedelta(days=1)}),
                             ("Drill", {"revoked_at": self.now}), ("Laser", {"superseded_by_id": ObjectId()})]:
            tool = self.db.tools.insert_one({"name": name}).inserted_id
            self.db.tool_checkouts.insert_one({"member_id": self.id, "tool_id": tool, **fields})
        self.assertEqual(self.source.checkouts(self.member, self.now), [("Lathe", ""), ("Saw", "")])
        self.assertEqual(self.source.checkouts(self.member, self.now + timedelta(hours=2)), [("Saw", "")])

    def task(self, title, value, status="repeatable", **fields):
        return self.db.volunteer_tasks.insert_one(
            {"title": title, "credit_value": value, "status": status, **fields}).inserted_id

    def event(self, title, value, **fields):
        self.db.volunteer_events.insert_one({"title": title, "credit_value": value, "status": "open", **fields})

    def ranked(self, member, limit=10):
        return [title for title, _ in self.source.opportunities(member, self.now, limit)]

    def test_ranked_fill_after_reserved_slots_includes_leftover_weekday_tasks(self):
        for title, val in [("A", 2), ("B", 1.5), ("C", 1.75), ("D", 0.5)]:
            self.task(title, val, day_of_week=0)
        self.task("Wrong day", 9, day_of_week=1)
        self.task("Every day", 5, "available")
        self.task("Cooling", 8, "recurring", next_available=self.today + timedelta(days=1))
        self.event("Event today", 6, event_date=self.today)
        self.event("Undated", 1)
        self.event("Yesterday", 8, event_date=self.today - timedelta(days=1))
        self.assertEqual(self.ranked(self.member, 5), ["A", "C", "Event today", "Every day", "B"])
        self.assertEqual(self.ranked(None), ["A", "C", "B", "Event today", "Every day", "Undated", "D"])
        self.assertEqual(self.ranked(self.member, 1), ["A"])

    def test_reusable_claims_pending_repeat_claims_and_event_attendance(self):
        for title, status, child in [("Once", "reusable", "completed"), ("Working", "repeatable", "pending"),
                                     ("Again", "repeatable", "completed"), ("Released", "reusable", "denied")]:
            parent = self.task(title, 2, status)
            self.task("Child", 10, child, parent_task_id=parent, claimed_by_id=self.id)
        self.event("Already joined", 10, attendee_ids=[str(self.id)])
        self.event("Tomorrow", 1, event_date=self.today + timedelta(days=1))
        self.assertEqual(self.ranked(self.member), ["Again", "Released", "Tomorrow"])
        self.assertIn("Already joined", self.ranked(None))

    def test_bounty_restrictions_and_staff_prerequisite_exemptions(self):
        tool = ObjectId()
        self.task("Staff or trained", 3, prerequisite_tool_ids=[str(tool)])
        self.event("Staff event", 2, prerequisite_tool_ids=[tool])
        for key, title, status, reporter in [(10, "Cooling fan", "open", ObjectId()),
                                             (ObjectId(), "My report", "open", self.id),
                                             (9, "Closed report", "resolved", ObjectId())]:
            self.db.fix_tickets.insert_one({"_id": key, "status": status, "reporter_id": reporter})
            self.task(title, 4, ticket_id=key, prerequisite_tool_ids=[tool])
        self.task("Orphan bounty", 5, ticket_id=8)
        self.assertEqual(self.ranked(self.member), [])
        self.assertEqual(self.ranked(replace(self.member, role="resource_manager")), ["Staff or trained", "Staff event"])
        self.db.tool_checkouts.insert_one({"member_id": self.id, "tool_id": tool})
        self.assertEqual(self.ranked(self.member), ["Cooling fan", "Staff or trained", "Staff event"])
        self.assertEqual(self.ranked(None), ["Cooling fan", "My report", "Staff or trained", "Staff event"])

    def test_eventbrite_scope_and_local_day(self):
        for title, extra in [("Public class", {}), ("Draft", {"status": "draft"}),
                             ("Private", {"restricted": True}), ("Unlisted", {"listed": False}),
                             ("Old", {"invalidated_at": self.now}), ("Series", {"series_parent": True}),
                             ("Other org", {"organization_id": "other"}),
                             ("Tomorrow", {"starts_at": self.now + timedelta(hours=2)})]:
            self.db.eventbrite_events.insert_one({"listed": True, "name": title, "status": "live",
                "starts_at": self.now, "organization_id": "space", **extra})
        self.assertEqual(self.source.eventbrite(self.now), [("Public class", "10:00 PM")])

    def test_net_leaderboard_resolves_members_before_limiting(self):
        def credit(member_id, status, value):
            self.db.volunteer_credits.insert_one({"member_id": member_id, "status": status, "credit_value": value})
        credit(self.id, "approved", 6.5)
        credit(self.id, "reversal", -2)
        credit(self.id, "pending", 100)
        for i in range(12):
            missing = ObjectId()
            credit(missing, "approved", 10)
            if i % 2:
                self.db.members.insert_one({"_id": missing, "merged_at": self.now})
        self.assertEqual(self.source.leaderboard(), [("Robin D.", "4.5 pts")])

    def test_recent_seed_normalizes_legacy_times_and_includes_exact_window_edges(self):
        end = self.now.replace(hour=13)  # The 16-hour window crosses local midnight.
        start = end - timedelta(hours=16)
        t = int(end.timestamp())
        for i, value in enumerate([t, (t - 1) * 1000, end - timedelta(seconds=2),
                                   (end - timedelta(seconds=3)).isoformat(), str(t - 4), str((t - 5) * 1000)]):
            self.db.checkins.insert_one({"holder": f"Demo{i} Example", ("time" if i % 2 else "timeOf"): value})
        self.db.checkins.insert_one({"_id": int(start.timestamp()), "name": "At cutoff"})
        self.db.checkins.insert_one({"holder": "Old", "timeOf": start - timedelta(seconds=1), "time": t})
        self.db.checkins.insert_one({"holder": "Future", "timeOf": end + timedelta(milliseconds=1)})
        self.assertEqual([event.name for event in self.source.recent(end)],
                         [f"Demo{i} Example" for i in range(6)] + ["At cutoff"])

    def test_recent_seed_resolves_multiple_cards_before_taking_ten_unique_members(self):
        self.db.cards.insert_one({"uid": "00EE", "member_id": self.id})
        for i in range(12):
            self.db.checkins.insert_one({"name": f"Guest{i}", "timeOf": self.now - timedelta(minutes=i + 1)})
        for i in range(18):
            card = {"uid": self.uid.lower()} if i % 2 else {"cardUID": "00ee"}
            self.db.checkins.insert_one({**card, "reader": "entry", "timeOf": self.now - timedelta(seconds=i)})
        entries = self.source.recent(self.now)
        self.assertEqual([r.name for r in entries], ["Robin Demo"] + [f"Guest{i}" for i in range(9)])
        self.assertEqual((entries[0].member_id, entries[0].at, entries[0].location), (self.id, self.now, "entry"))

    def test_local_day_bounds_follow_daylight_saving_time(self):
        for instant, hours in [(datetime(2026, 3, 8, 14, tzinfo=UTC), 23), (datetime(2026, 11, 1, 14, tzinfo=UTC), 25)]:
            begin, finish = day_bounds(instant)
            self.assertEqual(finish - begin, timedelta(hours=hours))
            self.assertEqual(finish.astimezone(EASTERN).hour, 0)

    def test_private_kudos_only_after_recipient_delivery(self):
        for i, status in enumerate(["delivered", "pending", "failed", "delivered"]):
            self.ledger_db.ledger_evidence.insert_one({"kind": "kudos", "public": False, "recipient": str(self.id),
                "message": f"Thanks {i}", "deliveries": {"recipient": {"status": status}}, "at": self.now + timedelta(days=i)})
        self.ledger_db.ledger_participants.insert_one({"_id": str(self.id), "opted_in": False})
        self.assertEqual(self.ledger.details(self.member, self.now).sections[0],
                         ("Kudos received", [("Thanks 3", ""), ("Thanks 0", "")]))

    def test_character_identity_rank_progress_and_avatar_visibility(self):
        key = str(self.id)
        db = self.ledger_db
        self.db.slack_users.insert_one({"member_id": self.id, "slack_id": "U123"})
        db.ledger_participants.insert_one({"_id": key, "opted_in": True, "rank": 1, "xp": "25.5",
                                           "metrics": {"first_build": 1}})
        db.ledger_awards.insert_one({"member_id": key})
        db.ledger_catalog.insert_one({"_id": "rank_display", "ranks": [{"name": "Maker", "slot": 1}]})
        db.ledger_avatars.insert_one({"_id": "current:" + key, "rank": 1, "slack_id": "U123", "kind": "current",
                                      "revision": "r1", "avatar": {"file_id": "F1"}, "avatar512": {"file_id": "F2"}})
        shop = self.db.shops.insert_one({"name": "Shop"}).inserted_id
        base = self.db.tools.insert_one({"name": "Orientation", "shop_id": shop, "open": True}).inserted_id
        tool = self.db.tools.insert_one({"name": "Lathe", "shop_id": shop, "prerequisite_ids": [base]}).inserted_id
        self.db.tool_checkouts.insert_one({"member_id": self.id, "tool_id": tool})
        details = self.ledger.details(self.member, self.now)
        self.assertEqual(details.avatar.file_id, "F2")
        self.assertEqual(details.sections[0][1], [("Maker", "25.5 XP"), ("Deepest cleared skill", "Lathe"),
                                                   ("Recorded achievements", "1")])
        self.assertEqual(details.sections[1][1], [("First Build", "1")])
        db.ledger_avatars.update_one({"_id": "current:" + key}, {"$set": {"rank": 2}})
        self.assertIsNone(self.ledger.details(self.member, self.now).avatar)
        db.ledger_avatars.update_one({"_id": "current:" + key}, {"$set": {"rank": 1}})
        db.ledger_participants.update_one({"_id": key}, {"$set": {"preferences.avatars": False}})
        self.assertIsNone(self.ledger.details(self.member, self.now).avatar)
        db.ledger_catalog.insert_one({"_id": "control", "paused": True})
        self.assertEqual(self.ledger.details(self.member, self.now).sections[0][1][0][0], "The Ledger is paused.")
        db.ledger_catalog.delete_one({"_id": "control"})
        self.db.slack_users.insert_one({"member_id": ObjectId(), "slack_id": "U123"})
        self.assertIsNone(self.ledger.details(self.member, self.now).rank)

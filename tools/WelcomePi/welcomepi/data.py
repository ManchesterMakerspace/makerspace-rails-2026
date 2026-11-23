"""Projected, read-only queries against the makerspace Rails collections."""
from datetime import datetime, time, timedelta
from heapq import nlargest
from threading import Lock

from bson import ObjectId
from pymongo import MongoClient

from .state import CARD_FIELDS, EASTERN, MEMBER_FIELDS, UTC, Directory, checkin_time, day_bounds, identify


def database_provider(uri):
    """Connect on a worker, including SRV DNS and TLS initialization."""
    lock = Lock()
    database = None

    def get():
        nonlocal database
        with lock:
            if database is None:
                client = MongoClient(uri, connect=False, tz_aware=True, appname="WelcomePi",
                                     serverSelectionTimeoutMS=3000, connectTimeoutMS=3000,
                                     socketTimeoutMS=6000, maxPoolSize=8)
                database = client.get_default_database()
        return database

    return get


def object_id(value):
    return ObjectId(value) if isinstance(value, str) and ObjectId.is_valid(value) else value


def names(collection, ids):
    ids = {object_id(value) for value in ids if value is not None}
    if not ids:
        return {}
    return {str(row["_id"]): row["name"] for row in collection.find(
        {"_id": {"$in": list(ids)}}, ["name"]) if row.get("name")}


def clock_label(value):
    return value.astimezone(EASTERN).strftime("%I:%M %p").lstrip("0")


def points(value):
    return f"{value:g} pt" if value == 1 else f"{value:g} pts"


class RailsData:
    def __init__(self, database, organization_ids=()):
        self.database = database
        self.organization_ids = organization_ids

    @property
    def db(self):
        return self.database()

    def directory(self):
        cache = Directory()
        for member in self.db.members.find({"merged_at": None}, list(MEMBER_FIELDS)):
            cache.update("members", "insert", member)
        for card in self.db.cards.find({}, list(CARD_FIELDS)):
            cache.update("cards", "insert", card)
        return cache

    def identity(self, uid, now):
        cards = list(self.db.cards.find({"uid": uid}, list(CARD_FIELDS)).limit(2))
        if len(cards) != 1:
            return None
        member = self.db.members.find_one({"_id": cards[0].get("member_id"), "merged_at": None},
                                          list(MEMBER_FIELDS))
        return identify(cards[0], member, now)

    def valid_tools(self, member_id, now):
        # Mongoid Date is stored as midnight UTC for the calendar label.
        today = datetime.combine(now.astimezone(EASTERN).date(), time.min, UTC)
        query = {"member_id": member_id, "revoked_at": None, "superseded_by_id": None,
                 "$or": [{"expires_on": None}, {"expires_on": {"$gte": today}}]}
        return {row["tool_id"] for row in self.db.tool_checkouts.find(query, ["tool_id"])
                if row.get("tool_id") is not None}

    def checkouts(self, member, now):
        tools = names(self.db.tools, self.valid_tools(member.member_id, now))
        return [(name, "") for name in sorted(tools.values(), key=str.casefold)]

    def reservations(self, member, now):
        now = now.astimezone(UTC)
        query = {"member_id": member.member_id, "status": {"$in": ["approved", "pending", "unpaid"]},
                 "start_at": {"$lt": now + timedelta(hours=12)}, "end_at": {"$gt": now}}
        fields = ["start_at", "end_at", "shop_id", "tool_ids", "reservation_scope", "title", "status"]
        rows = list(self.db.reservations.find(query, fields).sort([("start_at", 1), ("_id", 1)]))
        shops = names(self.db.shops, (r.get("shop_id") for r in rows))
        tools = names(self.db.tools, (tool for r in rows for tool in r.get("tool_ids", [])))
        today = now.astimezone(EASTERN).date()

        def when(dt):
            date = dt.astimezone(EASTERN)
            prefix = date.strftime("%a ") if date.date() != today else ""
            return prefix + clock_label(dt)

        result = []
        for row in rows:
            resources = [shops.get(str(row.get("shop_id")))]
            resources.extend(tools.get(str(tool)) for tool in row.get("tool_ids", []))
            label = " · ".join(filter(None, resources)) or row.get("title") or "Reservation"
            period = f"{when(row['start_at'])} – {when(row['end_at'])}"
            if row["status"] != "approved":
                period += " · " + row["status"].title()
            result.append((label, period))
        return result

    def eventbrite(self, now):
        start, end = day_bounds(now)
        query = {"starts_at": {"$gte": start, "$lt": end}, "listed": True,
                 "restricted": {"$ne": True}, "invalidated_at": None, "series_parent": {"$ne": True},
                 "status": {"$in": ["live", "started", "ended", "completed"]}}
        if self.organization_ids:
            query["organization_id"] = {"$in": self.organization_ids}
        return [(row["name"], clock_label(row["starts_at"])) for row in
                self.db.eventbrite_events.find(query, ["name", "starts_at"]).sort([("starts_at", 1), ("_id", 1)])
                if row.get("name")]

    def opportunities(self, member, now, limit):
        today = now.astimezone(EASTERN).date()
        date_key = datetime.combine(today, time.min, UTC)
        weekday = (today.weekday() + 1) % 7
        tasks_query = {"parent_task_id": None, "$or": [
            {"status": "available"},
            {"status": {"$in": ["reusable", "repeatable"]}, "day_of_week": {"$in": [None, weekday]}},
            {"status": "recurring", "day_of_week": {"$in": [None, weekday]},
             "$or": [{"next_available": None}, {"next_available": {"$lte": date_key}}]}]}
        fields = ["title", "credit_value", "prerequisite_tool_ids"]
        tasks = list(self.db.volunteer_tasks.find(tasks_query, fields + ["status", "day_of_week", "ticket_id"]))
        ticket_ids = [t["ticket_id"] for t in tasks if t.get("ticket_id") is not None]
        tickets = {t["_id"]: t for t in self.db.fix_tickets.find(
            {"_id": {"$in": ticket_ids}, "status": {"$in": ["open", "in_progress", "waiting_for_parts"]}},
            ["reporter_id"])} if ticket_ids else {}
        events_query = {"status": "open", "$or": [{"event_date": None}, {"event_date": {"$gte": date_key}}]}
        cleared, claimed_once, in_progress = set(), set(), set()
        if member:
            cleared = {str(tool) for tool in self.valid_tools(member.member_id, now)}
            events_query["attendee_ids"] = {"$nin": [member.member_id, str(member.member_id)]}
            claims = self.db.volunteer_tasks.find({
                "claimed_by_id": member.member_id, "parent_task_id": {"$ne": None},
                "status": {"$in": ["claimed", "pending", "completed"]}}, ["parent_task_id", "status"])
            for claim in claims:
                claimed_once.add(claim["parent_task_id"])
                if claim["status"] != "completed":
                    in_progress.add(claim["parent_task_id"])

        def qualified(row, *, bounty=False):
            if not member or (not bounty and member.role in ("admin", "board_member", "resource_manager")):
                return True
            return all(str(tool) in cleared for tool in row.get("prerequisite_tool_ids", []))

        # Each candidate is ranked once across tasks and events. Only multi-use
        # parent tasks can earn a reserved weekday slot.
        candidates = []
        for task in tasks:
            linked = task.get("ticket_id") is not None
            if linked:
                ticket = tickets.get(task["ticket_id"])
                if not ticket or (member and ticket.get("reporter_id") == member.member_id):
                    continue
            blocked = claimed_once if task["status"] == "reusable" else in_progress
            if task["_id"] in blocked or not qualified(task, bounty=linked):
                continue
            priority = task["status"] != "available" and task.get("day_of_week") == weekday
            candidates.append((task, "task", priority))
        for event in self.db.volunteer_events.find(events_query, fields + ["event_date"]):
            if qualified(event):
                candidates.append((event, "event", False))
        candidates.sort(key=lambda c: (-c[0].get("credit_value", 1), c[0]["title"].casefold(),
                                       str(c[0]["_id"]), c[1]))
        promoted = [c for c in candidates if c[2]][:min(limit, 2 if member else 3)]
        promoted_ids = {(kind, row["_id"]) for row, kind, _ in promoted}
        rest = (c for c in candidates if (c[1], c[0]["_id"]) not in promoted_ids)
        chosen = (promoted + list(rest))[:limit]
        return [(row["title"], points(row.get("credit_value", 1))) for row, _, _ in chosen]

    def leaderboard(self):
        pipeline = [
            {"$match": {"status": {"$in": ["approved", "reversal"]}}},
            {"$group": {"_id": "$member_id", "total": {"$sum": "$credit_value"}}},
            {"$sort": {"total": -1, "_id": 1}},
            {"$lookup": {"from": "members", "localField": "_id", "foreignField": "_id", "as": "member"}},
            {"$unwind": "$member"}, {"$match": {"member.merged_at": None}}, {"$limit": 10},
            {"$project": {"first": "$member.firstname", "last": "$member.lastname", "total": 1}},
        ]
        rows = []
        for row in self.db.volunteer_credits.aggregate(pipeline):
            last = (row.get("last") or "").strip()
            short = (row.get("first") or "Member") + (" " + last[0] + "." if last else "")
            rows.append((short, points(row["total"])))
        return rows

    def recent(self, now):
        start, end = day_bounds(now)
        seconds, finish = start.timestamp(), end.timestamp()
        # Both legacy fields contain seconds, milliseconds and BSON dates.
        # ISO strings may carry a different zone; normalize before the final cut.
        ranges = [(seconds, finish), (seconds * 1000, finish * 1000), (start, end),
                  (str(int(seconds)), str(int(finish))), (str(int(seconds * 1000)), str(int(finish * 1000))),
                  ((start - timedelta(days=1)).date().isoformat(), (end + timedelta(days=2)).date().isoformat())]
        query = {"$or": [{field: {"$gte": low, "$lt": high}}
                         for field in ("timeOf", "time") for low, high in ranges]}
        records = self.db.checkins.find(query, ["timeOf", "time", "holder", "name", "uid"])
        dated = ((stamp, row) for row in records if (stamp := checkin_time(row)) and start <= stamp < end)
        recent = nlargest(5, dated, key=lambda pair: (pair[0], str(pair[1]["_id"])))
        result = []
        for stamp, row in recent:
            name = (row.get("holder") or row.get("name") or "").split()
            if name:
                first = name[0]
            else:
                # Some reader versions recorded only a UID.
                card = self.db.cards.find_one({"uid": row.get("uid")}, ["member_id"]) if row.get("uid") else None
                member = self.db.members.find_one({"_id": card["member_id"], "merged_at": None},
                                                  ["firstname"]) if card and card.get("member_id") else None
                first = (member or {}).get("firstname") or "Member"
            result.append((first, clock_label(stamp)))
        return result

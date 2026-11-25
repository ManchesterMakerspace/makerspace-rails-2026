"""Display transitions and the in-memory index of door credentials."""
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo


EASTERN = ZoneInfo("America/New_York")
UTC = timezone.utc
HOME = "HTTPS://MEMBERS.MANCHESTERMAKERSPACE.ORG/HOME"
PERSONAL_SECONDS = 120
HANDOFF_SECONDS = 30
SLEEP_SECONDS = 4 * 3600
MEMBER_FIELDS = ("_id", "firstname", "lastname", "status", "role", "expirationTime", "merged_at")
CARD_FIELDS = ("_id", "uid", "member_id", "validity")


def uid_key(uid):
    if isinstance(uid, str) and uid and all(c in "0123456789ABCDEFabcdef" for c in uid):
        return uid.upper()
    return uid


def day_bounds(now):
    today = now.astimezone(EASTERN).date()
    start = datetime.combine(today, time.min, EASTERN)
    return start.astimezone(UTC), (start + timedelta(days=1)).astimezone(UTC)


def clock_label(value):
    return value.astimezone(EASTERN).strftime("%I:%M %p").lstrip("0")


def checkin_time(doc):
    for field in ("timeOf", "time"):
        value = doc.get(field)
        if isinstance(value, datetime):
            return value.astimezone(UTC) if value.tzinfo else value.replace(tzinfo=UTC)
        if isinstance(value, str) and len(value) in (10, 13) and value.isascii() and value.isdecimal():
            value = int(value)
        if isinstance(value, (float, int)) and not isinstance(value, bool) and value > 0:
            try:
                return datetime.fromtimestamp(value / 1000 if value > 10**10 else value, UTC)
            except (ValueError, OverflowError, OSError):
                continue
        if isinstance(value, str):
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                return (parsed if parsed.tzinfo else parsed.replace(tzinfo=EASTERN)).astimezone(UTC)
            except ValueError:
                continue
    return None


@dataclass(frozen=True)
class Identity:
    member_id: object
    card_id: object
    uid: str
    first: str
    role: str
    expires_ms: int
    last: str = ""

    def valid(self, now):
        return self.expires_ms > now.timestamp() * 1000


def identify(card, member, now):
    if not card or not member or card.get("validity") != "activeMember" or card.get("member_id") != member["_id"]:
        return None
    if member.get("merged_at") is not None or member.get("status") != "activeMember":
        return None
    expiry = member.get("expirationTime")
    if not isinstance(expiry, int) or expiry <= now.timestamp() * 1000:
        return None
    return Identity(member["_id"], card["_id"], card["uid"],
                    member.get("firstname") or "member", member.get("role") or "member", expiry,
                    member.get("lastname") or "")


class Directory:
    def __init__(self):
        self.members = {}
        self.cards = {}
        self.by_uid = defaultdict(set)

    def update(self, collection, operation, doc):
        key = doc["_id"]
        if collection == "members":
            if operation == "delete" or doc.get("merged_at") is not None:
                self.members.pop(key, None)
            else:
                self.members[key] = doc
            return
        previous = self.cards.pop(key, None)
        if previous:
            key_uid = uid_key(previous["uid"])
            ids = self.by_uid[key_uid]
            ids.discard(key)
            if not ids:
                del self.by_uid[key_uid]
        if operation != "delete" and isinstance(doc.get("uid"), str) and doc["uid"]:
            self.cards[key] = doc
            self.by_uid[uid_key(doc["uid"])].add(key)

    def card_for_uid(self, uid):
        ids = self.by_uid.get(uid_key(uid))
        if not ids or len(ids) != 1:
            return None
        return self.cards[next(iter(ids))]

    def lookup(self, uid, now):
        card = self.card_for_uid(uid)
        if card:
            return identify(card, self.members.get(card.get("member_id")), now)


class Screen:
    """A door greeting can show a first name. Personal pages require an identity."""

    def __init__(self, started):
        self.page = "board"
        self.greeting = False
        self.record_first = ""
        self.member = None
        self.pending = None
        self.generation = 0
        self.entered = self.last_activity = started

    def show(self, page, at, member=None, *, record_first=""):
        self.page, self.member, self.entered = page, member, at
        self.record_first = record_first
        self.greeting = page == "agenda"
        self.pending = None
        self.generation += 1

    def greet_record(self, name, at):
        first = name.split()[0]
        if self.page == "details":
            return False
        self.last_activity = max(at, self.last_activity)
        if self.page != "welcome" or self.record_first != first:
            self.show("welcome", at, record_first=first)
        return True

    def enrich_greeting(self, member):
        """Keep the first frame and its activity clock while the agenda loads."""
        self.page, self.member, self.greeting = "agenda", member, True

    def scan(self, member, local, at):
        self.last_activity = max(at, self.last_activity)
        same = self.member is not None and member.member_id == self.member.member_id
        if same:
            if local and self.page == "agenda":
                self.show("details", at, member)
            elif local:
                self.show("board", at)
            return
        if not local and self.page == "details" and at < self.entered + HANDOFF_SECONDS:
            self.pending = member
            return
        self.show("agenda", at, member)

    def tick(self, at, now):
        idle = at - self.last_activity
        if idle >= SLEEP_SECONDS:
            if self.page != "sleep":
                self.show("sleep", at)
        elif ((self.page in ("welcome", "agenda", "details") and idle >= PERSONAL_SECONDS)
              or (self.member and not self.member.valid(now))):
            self.show("board", at)
        elif self.pending and at >= self.entered + HANDOFF_SECONDS:
            arrival, self.pending = self.pending, None
            if arrival.valid(now):
                self.show("agenda", at, arrival)

    def reconcile(self, directory, now, at):
        if self.pending:
            current = directory.lookup(self.pending.uid, now)
            self.pending = current if current and current.member_id == self.pending.member_id else None
        if self.member:
            current = directory.lookup(self.member.uid, now)
            if not current or current.member_id != self.member.member_id:
                self.show("board", at)
            elif current != self.member:
                self.member = current
                self.generation += 1

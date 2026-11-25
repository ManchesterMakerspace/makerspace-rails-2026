"""The ten latest distinct door arrivals in a rolling sixteen-hour window."""
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta

from bson import ObjectId

from .state import UTC, clock_label, uid_key


RECENT_WINDOW = timedelta(hours=16)
# The welcome and insert publishers timestamp different stages of a door tap.
COPY_INTERVAL = timedelta(seconds=10)


def string_value(value):
    return value.strip() if isinstance(value, str) else ""


def compatible_names(left, right):
    # The welcome message may have only a first name, while the door record
    # has the same member's full name. Keep different full names distinct.
    a, b = left.casefold().split(), right.casefold().split()
    return not a or not b or a == b or (a[0] == b[0] and min(len(a), len(b)) == 1)


@dataclass(frozen=True)
class Checkin:
    at: datetime
    uid: str = ""
    name: str = ""
    location: str = "blank:"
    member_id: object = None
    live_card: bool = field(default=False, compare=False, repr=False)

    @classmethod
    def from_document(cls, doc, at):
        name = string_value(doc.get("holder")) or string_value(doc.get("name"))
        location = string_value(doc.get("where")) or string_value(doc.get("reader")) or "blank:"
        card_uid = string_value(doc.get("cardUID"))
        uid = string_value(doc.get("uid")) or card_uid
        if card_uid and uid_key(card_uid) != uid_key(uid):
            uid = ""  # A record with conflicting card identifiers cannot identify its owner.
        member_id = doc.get("member_id")
        if not isinstance(member_id, (str, int, ObjectId)) or isinstance(member_id, bool):
            member_id = None
        elif isinstance(member_id, str):
            member_id = member_id.strip() or None
        return cls(at, uid, " ".join(name.split()), location, member_id)

    def _with_owner(self, member_id, first, last, *, live=False):
        full_name = " ".join(filter(None, (string_value(first), string_value(last))))
        if live:
            return replace(self, member_id=member_id, name=full_name or self.name, live_card=True)
        if self.member_id is not None and str(self.member_id) != str(member_id):
            return self
        if not compatible_names(self.name, full_name):
            # The UID may have been reassigned since this door scan.
            return self
        name = self.name or full_name
        if len(name.split()) == 1 and len(full_name.split()) > 1:
            name = full_name
        return replace(self, member_id=member_id, name=name)

    def with_member(self, member):
        if not self.uid or uid_key(self.uid) != uid_key(member.uid):
            return self
        return self._with_owner(member.member_id, member.first, member.last, live=True)

    def with_directory(self, directory, *, live=False):
        card = directory.card_for_uid(self.uid) if directory else None
        if live or (self.live_card and self.member_id is None):
            if not self.uid:
                return replace(self, member_id=None) if self.member_id is not None else self
            owner = directory.members.get(card.get("member_id")) if card else None
            if owner:
                return self._with_owner(owner["_id"], owner.get("firstname"), owner.get("lastname"), live=True)
            return replace(self, member_id=None, live_card=True)
        member_id = self.member_id if self.member_id is not None else (card or {}).get("member_id")
        member = directory.members.get(member_id) if directory else None
        if member is None:
            return self
        return self._with_owner(member["_id"], member.get("firstname"), member.get("lastname"))

    def match(self, other):
        """Rank matches by member, card, full name, then a nearby first-name welcome."""
        if self.member_id is not None and other.member_id is not None:
            return 4 if str(self.member_id) == str(other.member_id) else 0
        if self.uid and other.uid:
            same_owner = (self.live_card and other.live_card) or compatible_names(self.name, other.name)
            return 3 if same_owner and uid_key(self.uid) == uid_key(other.uid) else 0
        if not compatible_names(self.name, other.name):
            return 0
        if self.name and other.name:
            if self.name.casefold() == other.name.casefold():
                if len(self.name.split()) > 1 or (self.name_only() and other.name_only()):
                    return 2
            # A welcome with only a first name could belong to a namesake.
            # Correlate it with the fuller copy of this tap at the same door.
            if self.location.casefold() == other.location.casefold() and abs(self.at - other.at) <= COPY_INTERVAL:
                return 1
        return 0

    def name_only(self):
        return self.member_id is None and not self.uid

    def order(self):
        member = str(self.member_id) if self.member_id is not None else ""
        return self.at, member, uid_key(self.uid), self.name, self.location, self.uid

    def merge(self, other):
        newest, earlier = sorted((self, other), key=Checkin.order, reverse=True)
        name = newest.name or earlier.name
        verified = next((entry for entry in (newest, earlier)
                         if entry.live_card and entry.member_id is not None and entry.name), None)
        if verified:
            name = verified.name
        elif len(name.split()) == 1 and len(earlier.name.split()) > 1 and compatible_names(name, earlier.name):
            name = earlier.name
        member_id = newest.member_id if newest.member_id is not None else earlier.member_id
        return replace(newest, member_id=member_id,
                       uid=newest.uid or earlier.uid, name=name)


class RecentCheckins:
    def __init__(self):
        self.entries = []

    def _expire(self, now):
        start = now.astimezone(UTC) - RECENT_WINDOW
        self.entries = [entry for entry in self.entries if start <= entry.at <= now]
        return start

    def add(self, record, now):
        start = self._expire(now)
        if not start <= record.at <= now or (record.name_only() and not record.name):
            return
        matches = [(record.match(entry), entry) for entry in self.entries]
        # A resolved scan can link an earlier visit by the member's other
        # card and a provisional row for this UID from before verification.
        candidates = [entry for score, entry in matches if score >= 3]
        if candidates:
            if len({str(entry.member_id) for entry in candidates if entry.member_id is not None}) > 1:
                return  # A reassigned UID, without enough information to identify its owner.
            # A fuller copy can also identify a provisional welcome for this tap.
            candidates.extend(entry for score, entry in matches if 0 < score < 3 and entry.name_only())
        else:
            strength = max((score for score, _ in matches), default=0)
            candidates = [entry for score, entry in matches if strength and score == strength]
            if len(candidates) > 1:
                return  # A name alone cannot disambiguate these members.
        for entry in candidates:
            self.entries.remove(entry)
            record = record.merge(entry)
        self.entries.append(record)
        self.entries.sort(key=Checkin.order, reverse=True)
        del self.entries[10:]

    def resolve(self, directory, now):
        entries, self.entries = self.entries, []
        for entry in entries:
            self.add(entry.with_directory(directory), now)

    def rows(self, now):
        self._expire(now)
        return [((entry.name or "Member").split()[0], clock_label(entry.at)) for entry in self.entries[:5]]

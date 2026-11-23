"""Read the Ledger's character sheet, delivered kudos and current private artwork."""
from dataclasses import dataclass
import hashlib
from io import BytesIO
import json
import logging
import re
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from PIL import Image
from pymongo.errors import PyMongoError


@dataclass(frozen=True)
class Avatar:
    file_id: str
    revision: str
    checksum: str


@dataclass
class Details:
    sections: list
    rank: int | None = None
    avatar: Avatar | None = None


def deepest_skill(tools, cleared):
    """Ledger ranks cleared tools by depth in the enabled prerequisite graph."""
    pending = {str(row["_id"]): row for row in tools}
    depths, candidates = {}, []
    while pending:
        resolved = []
        for key, tool in pending.items():
            prerequisites = [str(p) for p in tool.get("prerequisite_ids", [])]
            if not all(p in depths for p in prerequisites):
                continue
            depth = 1 + max((depths[p] for p in prerequisites), default=-1)
            depths[key] = depth
            if key in cleared and not tool.get("open") and tool.get("name"):
                candidates.append((-depth, tool["name"].casefold(), key, tool["name"]))
            resolved.append(key)
        if not resolved:  # Cycles and missing prerequisites cannot establish a depth.
            break
        for key in resolved:
            del pending[key]
    return min(candidates)[3] if candidates else "No recorded clearance"


class LedgerData:
    def __init__(self, database, rails, excluded, slack_token):
        self.database = database
        self.rails = rails
        self.excluded = excluded
        self.token = slack_token

    def slack_id(self, member):
        links = self.rails.db.slack_users
        rows = list(links.find({"member_id": member.member_id, "invalidated_at": None}, ["slack_id"]).limit(2))
        uid = rows[0].get("slack_id") if len(rows) == 1 else None
        if not isinstance(uid, str) or not re.fullmatch("[UW][A-Z0-9]+", uid) or uid in self.excluded:
            return None
        if links.count_documents({"slack_id": uid, "invalidated_at": None}, limit=2) != 1:
            return None
        return uid

    def participant(self, member):
        db = self.database()
        key = str(member.member_id)
        record = db.ledger_participants.find_one({"_id": key, "opted_in": True},
            ["rank", "xp", "metrics", "import_pending", "preferences.avatars"])
        if not record:
            return None, None
        uid = self.slack_id(member)
        identity = db.ledger_catalog.find_one({"_id": "identity:" + key}, ["deactivated", "bot"]) or {}
        if not uid or identity.get("deactivated") or identity.get("bot"):
            return None, None
        return record, uid

    def paused(self):
        control = self.database().ledger_catalog.find_one({"_id": "control"}, ["paused"])
        return bool(control and control.get("paused"))

    def artwork(self, member, participant, uid):
        if not participant or not participant.get("preferences", {}).get("avatars", True):
            return None
        try:
            current = self.database().ledger_avatars.find_one(
                {"_id": "current:" + str(member.member_id), "kind": "current",
                 "rank": participant["rank"], "slack_id": uid},
                ["avatar.file_id", "avatar512.file_id", "avatar512.sha256", "revision"])
        except PyMongoError as error:
            logging.getLogger(__name__).warning("Avatar reference unavailable (%s)", type(error).__name__)
            return None
        small = (current or {}).get("avatar512") or {}
        if not small.get("file_id") or not current.get("revision") or not (current.get("avatar") or {}).get("file_id"):
            return None
        return Avatar(small["file_id"], current["revision"], small.get("sha256", ""))

    def details(self, member, now):
        db = self.database()
        key = str(member.member_id)
        participant, uid = self.participant(member)
        if not participant:
            kudos = db.ledger_evidence.find(
                {"kind": "kudos", "recipient": key, "deliveries.recipient.status": "delivered"},
                ["message", "at"]).sort([("at", -1), ("_id", -1)])
            return Details([("Kudos received", [(r["message"], "") for r in kudos if r.get("message")]),
                            ("Current checkouts", self.rails.checkouts(member, now))])
        if self.paused():
            return Details([("Character sheet", [("The Ledger is paused.", "")])])
        rank = participant["rank"]
        display = db.ledger_catalog.find_one({"_id": "rank_display"}, ["ranks.name", "ranks.slot"]) or {}
        title = "Participant" if not rank else next(
            (r["name"] for i, r in enumerate(display.get("ranks", []), 1) if r.get("slot", i) == rank),
            f"Rank {rank}")
        shops = self.rails.db.shops.distinct("_id", {"disabled": {"$ne": True}})
        tools = self.rails.db.tools.find({"disabled": {"$ne": True}, "shop_id": {"$in": shops}},
                                         ["name", "open", "prerequisite_ids"])
        cleared = self.rails.db.tool_checkouts.distinct("tool_id", {"member_id": member.member_id, "revoked_at": None})
        skill = deepest_skill(tools, {str(t) for t in cleared})
        achievements = db.ledger_awards.count_documents({"member_id": key})
        rows = [(title, f"{participant.get('xp', '0')} XP"), ("Deepest cleared skill", skill),
                ("Recorded achievements", str(achievements))]
        metrics = [(k.replace("_", " ").title(), str(v)) for k, v in sorted(participant.get("metrics", {}).items())]
        if participant.get("import_pending"):
            metrics.append(("Verified history import pending", ""))
        return Details([("Character sheet", rows), ("Progress", metrics)], rank,
                       self.artwork(member, participant, uid))

    def download(self, member, ref):
        if not self.token:
            return None
        image = fetch_avatar(self.token, ref)
        # The file/consent can change during the network round trip.
        participant, uid = self.participant(member)
        if self.paused() or self.artwork(member, participant, uid) != ref:
            return None
        return image


class PrivateFileRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # A redirect is not permission to forward a bearer token to another host.
        if urlsplit(newurl).scheme != "https" or urlsplit(newurl).netloc != urlsplit(req.full_url).netloc:
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_avatar(token, ref):
    opener = build_opener(PrivateFileRedirect())
    headers = {"Authorization": "Bearer " + token}
    info_url = "https://slack.com/api/files.info?" + urlencode({"file": ref.file_id})
    with opener.open(Request(info_url, headers=headers), timeout=4) as response:
        info = json.loads(response.read(128 * 1024))
    file = info.get("file", {})
    url = file.get("url_private_download", "")
    parts = urlsplit(url)
    if (not info.get("ok") or file.get("id") != ref.file_id or file.get("mimetype") != "image/jpeg"
            or parts.scheme != "https" or parts.netloc != "files.slack.com"):
        return None
    with opener.open(Request(url, headers=headers), timeout=4) as response:
        data = response.read(2_000_001)
    if len(data) > 2_000_000 or (ref.checksum and hashlib.sha256(data).hexdigest() != ref.checksum):
        return None
    with Image.open(BytesIO(data)) as image:
        if image.format == "JPEG" and image.size == (512, 512):
            return image.convert("RGB")
    return None

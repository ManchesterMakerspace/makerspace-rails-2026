"""Input adapters. Only projected identity changes and scan identifiers enter the UI queue."""
from collections import OrderedDict
from datetime import datetime
import logging
from pathlib import Path
import time

from bson import ObjectId, json_util
from bson.errors import BSONError
import paho.mqtt.client as mqtt

from .state import CARD_FIELDS, MEMBER_FIELDS, PERSONAL_SECONDS, UTC, checkin_time


LOG = logging.getLogger(__name__)
MUTATIONS = ("insert", "update", "replace", "delete")
TOPICS = [("checkins/insert", 2)] + [(f"{c}/{op}", 2) for c in ("members", "cards") for op in MUTATIONS]


class DoorFeed:
    def __init__(self):
        self.seen = OrderedDict()

    def message(self, topic, payload, retained, now, monotonic):
        collection, operation = topic.split("/")
        if (topic, 2) not in TOPICS:
            return None
        if retained:
            return None if collection == "checkins" else ("resync",)
        prefix, published, body = payload.decode("utf-8").split(" ", 2)
        if prefix != operation:
            raise ValueError("Operation differs from topic")
        published = int(published)
        document = json_util.loads(body)["document"]
        if not isinstance(document, dict) or not isinstance(document.get("_id"), (ObjectId, str, int)):
            return ("resync",) if collection != "checkins" else None
        if collection != "checkins":
            # updateLookup can yield only documentKey when a full document
            # could not be supplied. Never install a patch as a complete record.
            if operation in ("update", "replace") and ("uid" if collection == "cards" else "status") not in document:
                return ("resync",)
            fields = MEMBER_FIELDS if collection == "members" else CARD_FIELDS
            projected = {k: document[k] for k in fields if k in document}
            return ("change", collection, operation, projected)
        stamp = checkin_time(document)
        if not stamp or not isinstance(document.get("uid"), str) or not document["uid"]:
            return None
        for value in (published, stamp.timestamp()):
            if not -10 <= now.timestamp() - value < PERSONAL_SECONDS:
                return None
        while self.seen and next(iter(self.seen.values())) <= monotonic - PERSONAL_SECONDS - 10:
            self.seen.popitem(last=False)
        key = document["_id"]
        if key in self.seen:
            return None
        self.seen[key] = monotonic
        return ("scan", document["uid"], False, monotonic)


def start_mqtt(settings, emit):
    feed = DoorFeed()
    args = {"callback_api_version": mqtt.CallbackAPIVersion.VERSION2} if hasattr(mqtt, "CallbackAPIVersion") else {}
    client = mqtt.Client(client_id=settings.mqtt_id, clean_session=True, **args)
    if settings.mqtt_tls:
        client.tls_set()
    if settings.mqtt_user:
        client.username_pw_set(settings.mqtt_user, settings.mqtt_password)

    def connected(client, _data, _flags, rc, _properties=None):
        if rc == 0:
            client.subscribe(TOPICS)

    def subscribed(_client, _data, _mid, grants, _properties=None):
        if len(grants) == len(TOPICS) and all(getattr(qos, "value", qos) in (0, 1, 2) for qos in grants):
            emit("subscribed")
        else:
            LOG.warning("MQTT subscription refused; verify topic ACLs")
            emit("disconnected")

    def received(_client, _data, msg):
        try:
            event = feed.message(msg.topic, msg.payload, msg.retain, datetime.now(UTC), time.monotonic())
        except (BSONError, ValueError, KeyError, TypeError, OverflowError, AttributeError, OSError):
            LOG.warning("Ignoring malformed MQTT message on %s", msg.topic)
            event = ("resync",) if msg.topic.split("/")[0] in ("members", "cards") else None
        if event:
            emit(*event)

    client.on_connect = connected
    client.on_subscribe = subscribed
    client.on_disconnect = lambda *_: emit("disconnected")
    client.on_message = received
    client.reconnect_delay_set(min_delay=1, max_delay=30)
    client.connect_async(settings.mqtt_host, settings.mqtt_port, keepalive=30)
    client.loop_start()
    return client


class CardPresence:
    """Require an observed removal so a stationary card cannot cycle the display."""
    def __init__(self):
        self.held = None
        self.last_seen = 0

    def observe(self, uid, at):
        if uid is None:
            if at - self.last_seen >= 0.25:
                self.held = None
            return None
        self.last_seen = at
        if uid == self.held:
            return None
        self.held = uid
        return uid


def read_nfc(port, emit, stop):
    import nfc
    presence = CardPresence()
    target = nfc.clf.RemoteTarget("106A")
    while not stop.is_set():
        try:
            # /dev/serial0 can resolve to ttyAMA0 or ttyS0 on these Pi models.
            tty = Path(port).resolve().name
            if not tty.startswith("tty"):
                raise OSError("No UART device")
            with nfc.ContactlessFrontend("tty:" + tty[3:] + ":pn532") as reader:
                while not stop.is_set():
                    card = reader.sense(target)
                    raw = card.sdd_res if card is not None else None
                    at = time.monotonic()
                    uid = presence.observe(raw.hex().upper() if raw else None, at)
                    if uid:
                        emit("scan", uid, True, at)
                    stop.wait(0.08)
        except (OSError, nfc.clf.Error) as error:
            LOG.warning("NFC reader unavailable (%s); retrying", type(error).__name__)
            stop.wait(3)

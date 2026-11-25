"""Input adapters. Project check-in and identity messages before queuing them."""
from collections import deque
from dataclasses import dataclass
from datetime import datetime
import logging
import sys
from threading import RLock, Timer
import time

from bson import ObjectId, json_util
from bson.errors import BSONError
import paho.mqtt.client as mqtt

from .checkin_payload import parse_checkin
from .logs import driver_detail
from .recent import COPY_INTERVAL, Checkin, compatible_names
from .state import CARD_FIELDS, MEMBER_FIELDS, PERSONAL_SECONDS, UTC, uid_key


LOG = logging.getLogger(__name__)
MUTATIONS = ("insert", "update", "replace", "delete")
ACTIVITY = "activity/checkins/#"
TOPICS = [("checkins/insert", 2), (ACTIVITY, 2)] + [(f"{c}/{op}", 2) for c in ("members", "cards") for op in MUTATIONS]


@dataclass
class Arrival:
    received: float
    record: Checkin
    door_time: datetime
    ids: set
    sources: set


class DoorFeed:
    def __init__(self):
        self.seen = deque()
        self.last_public = None

    def first_delivery(self, record, source, identifier, door_time, monotonic):
        while self.seen and self.seen[0].received <= monotonic - PERSONAL_SECONDS - 10:
            self.seen.popleft()
        for arrival in reversed(self.seen):
            previous = arrival.record
            if record.location.casefold() != previous.location.casefold():
                continue
            if record.uid:
                # A name-only greeting may precede the first verifiable UID.
                if uid_key(record.uid) != uid_key(previous.uid):
                    continue
            elif not previous.name or not compatible_names(record.name, previous.name):
                continue
            # Copies from the activity and change-stream feeds may have unrelated
            # IDs and timestamps a few seconds apart. Pair each format once so
            # another genuine, rapid tap on the same reader can still wake it.
            other_format = source not in arrival.sources and abs(door_time - arrival.door_time) <= COPY_INTERVAL
            if identifier in arrival.ids or other_format:
                arrival.sources.add(source)
                arrival.ids.add(identifier)
                if record.uid and record.name and not previous.name:
                    # A name-only welcome may have displaced the first UID-only
                    # lookup. Give this fuller, independently credentialed copy
                    # one chance to complete the public greeting.
                    arrival.record = record
                    public = self.last_public
                    return (public is not None and public.location.casefold() == record.location.casefold()
                            and abs(door_time - public.at) <= COPY_INTERVAL
                            and compatible_names(record.name, public.name))
                return False
        self.seen.append(Arrival(monotonic, record, door_time, {identifier}, {source}))
        return True

    def message(self, topic, payload, retained, now, monotonic):
        if topic == "checkins/insert" or mqtt.topic_matches_sub(ACTIVITY, topic):
            record, operation, published, identifier, door_time = parse_checkin(payload)
            fresh = bool(record.uid or record.name) and not retained and all(
                -10 <= (now - stamp).total_seconds() < PERSONAL_SECONDS for stamp in (published, record.at))
            if fresh:
                fresh = self.first_delivery(record, (topic, operation), identifier, door_time, monotonic)
                if fresh:
                    self.last_public = None if record.uid else record
            return ("checkin", record, monotonic, topic, fresh)
        if (topic, 2) not in TOPICS:
            return None
        collection, operation = topic.split("/")
        if retained:
            return ("resync",)
        prefix, published, body = payload.decode("utf-8").split(None, 2)
        if prefix != operation:
            raise ValueError("Operation differs from topic")
        int(published)
        document = json_util.loads(body)["document"]
        if not isinstance(document, dict) or not isinstance(document.get("_id"), (ObjectId, str, int)):
            return ("resync",)
        # updateLookup can yield only documentKey when a full document
        # could not be supplied. Never install a patch as a complete record.
        if operation in ("update", "replace") and ("uid" if collection == "cards" else "status") not in document:
            return ("resync",)
        fields = MEMBER_FIELDS if collection == "members" else CARD_FIELDS
        projected = {k: document[k] for k in fields if k in document}
        return ("change", collection, operation, projected)


def reason_text(reason, legacy, properties=None):
    code = getattr(reason, "value", reason)
    description = str(reason) if hasattr(reason, "is_failure") else legacy(code)
    message = getattr(properties, "ReasonString", None)
    return f"{description} ({code})" + (f" — {message}" if message else "")


def start_mqtt(settings, emit):
    feed = DoorFeed()
    pending = None
    timer = None
    subscription_lock = RLock()

    def clear_subscription():
        nonlocal pending, timer
        with subscription_lock:
            if timer:
                timer.cancel()
            pending = timer = None

    def request_subscriptions(client):
        nonlocal pending, timer
        with subscription_lock:
            clear_subscription()
            rc, mid = client.subscribe(TOPICS)
            if rc != mqtt.MQTT_ERR_SUCCESS:
                LOG.error("MQTT subscribe failed: %s", reason_text(rc, mqtt.error_string))
                emit("disconnected")
                return
            pending = mid

            def timed_out():
                with subscription_lock:
                    if timer is deadline:
                        LOG.error("MQTT subscription ACK timed out after 20 seconds (packet %s). Retrying.", mid)
                        request_subscriptions(client)

            deadline = Timer(20, timed_out)
            deadline.daemon = True
            timer = deadline
            deadline.start()

    def connected(client, _data, _flags, rc, properties=None):
        if rc == 0:
            request_subscriptions(client)
        else:
            LOG.error("MQTT connection refused: %s", reason_text(rc, mqtt.connack_string, properties))
            emit("disconnected")

    def connection_failed(_client, _data):
        # Paho calls on_connect_fail inside its socket/TLS exception handler in 1.x and 2.x.
        error = sys.exc_info()[1]
        LOG.error("MQTT connection to %s:%s failed: %s", settings.mqtt_host, settings.mqtt_port,
                  driver_detail(error) if error else "Paho reported a connection failure")

    def subscribed(_client, _data, mid, grants, properties=None):
        with subscription_lock:
            if mid != pending:
                return
            clear_subscription()
        refused = [f"{topic}: {reason_text(qos, lambda _: 'subscription refused', properties)}"
                   for (topic, _), qos in zip(TOPICS, grants) if getattr(qos, "value", qos) not in (0, 1, 2)]
        if len(grants) != len(TOPICS):
            refused.append(f"received {len(grants)} of {len(TOPICS)} grants")
        if refused:
            LOG.error("MQTT subscription failed: %s", ", ".join(refused))
            emit("disconnected")
        else:
            emit("subscribed")

    def disconnected(_client, _data, flags_or_rc, reason=None, properties=None):
        clear_subscription()
        rc = flags_or_rc if reason is None else reason
        if rc != 0:
            LOG.error("MQTT disconnected: %s", reason_text(rc, mqtt.error_string, properties))
        emit("disconnected")

    def received(_client, _data, msg):
        try:
            event = feed.message(msg.topic, msg.payload, msg.retain, datetime.now(UTC), time.monotonic())
        except (BSONError, ValueError, KeyError, TypeError, OverflowError, AttributeError, OSError, RecursionError) as error:
            # BSON decode errors can quote field values. These are payload errors, not driver errors.
            LOG.warning("Malformed MQTT message on %s (%s)", msg.topic, type(error).__name__)
            event = ("resync",) if msg.topic.split("/")[0] in ("members", "cards") else None
        if event:
            emit(*event)

    def driver_log(_client, _data, level, message):
        if level == mqtt.MQTT_LOG_ERR:
            LOG.error("MQTT driver: %s", message)

    try:
        args = {"callback_api_version": mqtt.CallbackAPIVersion.VERSION2} if hasattr(mqtt, "CallbackAPIVersion") else {}
        client = mqtt.Client(client_id=settings.mqtt_id, clean_session=True, **args)
        if settings.mqtt_tls:
            client.tls_set()
        if settings.mqtt_user:
            client.username_pw_set(settings.mqtt_user, settings.mqtt_password)
        client.on_connect = connected
        client.on_connect_fail = connection_failed
        client.on_subscribe = subscribed
        client.on_disconnect = disconnected
        client.on_message = received
        client.on_log = driver_log
        client.reconnect_delay_set(min_delay=1, max_delay=30)
        client.connect_async(settings.mqtt_host, settings.mqtt_port, keepalive=30)
        rc = client.loop_start()
        if rc not in (None, mqtt.MQTT_ERR_SUCCESS):  # Paho 1.x returns None on success.
            raise RuntimeError(reason_text(rc, mqtt.error_string))
        return client
    except (OSError, ValueError, RuntimeError) as error:
        LOG.error("MQTT startup failed: %s", driver_detail(error))
        raise


def listen_mqtt(settings, emit, stop):
    while not stop.is_set():
        try:
            client = start_mqtt(settings, emit)
        except (OSError, ValueError, RuntimeError):
            stop.wait(5)
            continue
        try:
            stop.wait()
        finally:
            client.disconnect()
            client.loop_stop()
        return

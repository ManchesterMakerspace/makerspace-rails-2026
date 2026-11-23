"""Read-only commissioning probes, run by setup.sh in the service environment."""
import argparse
from dataclasses import replace
import logging
from queue import Empty, Queue
import sys
import time
from uuid import uuid4

from pymongo.errors import PyMongoError

from welcomepi.config import Settings
from welcomepi.data import database_provider
from welcomepi.inputs import start_mqtt
from welcomepi.logs import driver_detail, kiosk_logging
from welcomepi.reader import discover_reader


LOG = logging.getLogger(__name__)


class CheckFailed(Exception):
    """A diagnostic suitable for the terminal, without credentials or member data."""


def read_collections(uri, collections):
    db = database_provider(uri)()
    try:
        for name in collections:
            db[name].find_one({}, {"_id": 1})
    finally:
        db.client.close()


def probe_reader(settings):
    reader, report = discover_reader(settings)
    LOG.log(logging.INFO if reader else logging.WARNING, "%s", report)
    if reader:
        reader.close()
    print(report)


def probe_mqtt(settings, watch):
    events = Queue()

    def receive(kind, *_):
        if kind in ("subscribed", "disconnected", "scan"):
            events.put(kind)

    def wait_for(kind, seconds, timeout_message):
        deadline = time.monotonic() + seconds
        while True:
            try:
                event = events.get(timeout=max(0, deadline - time.monotonic()))
            except Empty:
                if kind == "subscribed":
                    LOG.error("MQTT commissioning timed out: %s", timeout_message)
                raise CheckFailed(timeout_message) from None
            if event == kind:
                return
            if event == "disconnected":
                raise CheckFailed("Broker disconnected or refused a subscription. Check TLS and broker ACLs.")

    # A second client with the kiosk's ID would disconnect the live display.
    settings = replace(settings, mqtt_id="wpi-check-" + uuid4().hex[:10])
    client = start_mqtt(settings, receive)
    try:
        wait_for("subscribed", 20, "No subscription acknowledgment in 20 seconds. Check the broker and its ACLs.")
        print("MQTT acknowledged all nine kiosk subscriptions.", flush=True)
        if watch:
            print("Listening. Make a genuine door check-in within 90 seconds.", flush=True)
            wait_for("scan", 90, "No fresh checkins/insert arrived in 90 seconds. Check the door, publisher and clock.")
            print("Received a fresh checkins/insert. Confirm the matching welcome on HDMI.")
    finally:
        client.disconnect()
        client.loop_stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check", "watch-door"))
    parser.add_argument("--reader-in-use", action="store_true")
    args = parser.parse_args()
    try:
        settings = Settings.load()
    except ValueError:
        print("Check the required values and their formats in /etc/welcomepi.env.", file=sys.stderr)
        return 1
    with kiosk_logging(settings):
        return run_checks(settings, args)


def run_checks(settings, args):
    checks = []
    if args.mode == "check":
        if args.reader_in_use:
            print("The kiosk owns reader discovery. Verify the selected reader with a local tap.")
        else:
            checks.append(("Reader discovery", probe_reader, (settings,)))
        checks.extend([
            ("Rails member, card and check-in reads", read_collections, (settings.rails_uri, ("members", "cards", "checkins"))),
            ("Ledger participant read", read_collections, (settings.ledger_uri, ("ledger_participants",))),
        ])
    checks.append(("MQTT", probe_mqtt, (settings, args.mode == "watch-door")))
    failed = False
    for label, probe, inputs in checks:
        try:
            probe(*inputs)
        except Exception as error:
            if isinstance(error, PyMongoError):
                LOG.error("MongoDB %s failed: %s", label, driver_detail(error))
            # Keep connection details in configured syslog, separate from operator output.
            reason = str(error) if isinstance(error, CheckFailed) else type(error).__name__
            print(f"FAIL  {label} ({reason})", file=sys.stderr)
            failed = True
        else:
            print(f"OK    {label}")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())

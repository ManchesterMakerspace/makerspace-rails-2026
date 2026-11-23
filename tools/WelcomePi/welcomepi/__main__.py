import logging
import signal
from threading import Event

from .app import run
from .config import Settings
from .display import Display


def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
    # nfcpy normally logs attached tags and PyMongo can log command metadata.
    for library in ("nfc", "pymongo", "paho"):
        logging.getLogger(library).setLevel(logging.WARNING)
    settings = Settings.load()
    stop = Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    run(settings, Display(settings.rotation), stop)


if __name__ == "__main__":
    main()

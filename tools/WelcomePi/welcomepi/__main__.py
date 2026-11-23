import signal
from threading import Event

from .app import run
from .config import Settings
from .display import Display
from .logs import kiosk_logging


def main():
    settings = Settings.load()
    stop = Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    with kiosk_logging(settings):
        run(settings, Display(settings.rotation), stop)


if __name__ == "__main__":
    main()

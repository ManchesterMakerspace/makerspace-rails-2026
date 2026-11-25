"""Kiosk syslog delivery. Only the listener thread writes to the logging socket."""
from contextlib import contextmanager
import logging
from logging.handlers import QueueHandler, QueueListener, SysLogHandler
from pathlib import Path
from queue import SimpleQueue
import re
import socket
from urllib.parse import unquote_plus

from pymongo import monitoring
from pymongo.errors import OperationFailure


LOCAL_SYSLOG = Path("/dev/log")
HDMI_CABLE_LOG = logging.getLogger("welcomepi.display.cable")


def driver_detail(error):
    if isinstance(error, OperationFailure) and error.details and error.details.get("errmsg"):
        # The full reply may contain the original command and private documents.
        return f"{type(error).__name__}: {driver_detail(error.details)}"
    if isinstance(error, dict):
        reason = error.get("errmsg") or error.get("codeName") or "Driver supplied no error message"
        reason = re.sub(r"(?is)(to execute command)\s+\{.*", r"\1 [redacted]", str(reason))
        code = error.get("code")
        return f"{reason} (code {code})" if code is not None else str(reason)
    return f"{type(error).__name__}: {error}"


class MongoFailures(monitoring.CommandListener, monitoring.ServerHeartbeatListener):
    """Include failures that a later driver retry may hide from the caller."""
    def started(self, event):
        pass

    def succeeded(self, event):
        pass

    def failed(self, event):
        if isinstance(event, monitoring.CommandFailedEvent):
            operation, failure = event.command_name, event.failure
        else:
            operation, failure = "heartbeat", event.reply
        logging.getLogger(__name__).error("MongoDB %s failed on %s: %s", operation,
                                          event.connection_id, driver_detail(failure))


class KioskFormatter(logging.Formatter):
    def __init__(self, settings):
        prefix = "%(asctime)s " + socket.gethostname() + " " if settings.syslog_server else ""
        super().__init__(prefix + "welcomepi[%(process)d]: %(levelname)s %(message)s", "%b %d %H:%M:%S")
        secrets = {settings.mqtt_password, settings.slack_token}
        for uri in (settings.rails_uri, settings.ledger_uri):
            authority = uri.partition("://")[2].split("/", 1)[0]
            credentials, _, _ = authority.rpartition("@")
            password = credentials.partition(":")[2]
            secrets.update((password, unquote_plus(password)))
        self.secrets = sorted(filter(None, secrets), key=len, reverse=True)

    def format(self, record):
        message = super().format(record)
        # Strip URI userinfo and options while retaining the server, driver reason and error code.
        message = re.sub(r"(?i)((?:mongodb(?:\+srv)?|mqtts?)://)[^/\s@]+@", r"\1[redacted]@", message)
        message = re.sub(r"(?i)((?:mongodb(?:\+srv)?|mqtts?)://[^\s?]*)\?[^\s]+", r"\1?[redacted]", message)
        for secret in self.secrets:
            message = message.replace(secret, "[redacted]")
        return "".join(c if c.isprintable() else " " for c in message)


@contextmanager
def kiosk_logging(settings):
    stderr = logging.StreamHandler()
    if settings.syslog_server:
        sink = SysLogHandler(address=settings.syslog_server, socktype=socket.SOCK_DGRAM,
                             facility=SysLogHandler.LOG_DAEMON)
        sink.append_nul = False
    elif LOCAL_SYSLOG.is_socket():
        sink = SysLogHandler(address=str(LOCAL_SYSLOG), facility=SysLogHandler.LOG_DAEMON)
    else:
        sink = stderr  # Local journal/console on hosts without a syslog socket.
    formatter = KioskFormatter(settings)
    sink.setFormatter(formatter)
    queue = SimpleQueue()
    handler = QueueHandler(queue)
    listener = QueueListener(queue, sink)
    root = logging.getLogger()
    old_handlers, old_level, old_raise = root.handlers[:], root.level, logging.raiseExceptions
    libraries = [logging.getLogger(name) for name in ("nfc", "pymongo", "paho")]
    levels = [logger.level for logger in libraries]
    for logger in libraries:
        logger.setLevel(logging.WARNING)
    root.handlers[:] = [handler]
    root.setLevel(logging.INFO)
    logging.raiseExceptions = False  # A failed remote send must not echo the record to local stderr.
    listener.start()
    if sink is not stderr:
        stderr.setFormatter(formatter)
        HDMI_CABLE_LOG.addHandler(stderr)
    try:
        yield
    finally:
        if sink is not stderr:
            HDMI_CABLE_LOG.removeHandler(stderr)
            stderr.close()
        root.handlers[:] = old_handlers
        root.setLevel(old_level)
        listener.stop()
        sink.close()
        handler.close()
        logging.raiseExceptions = old_raise
        for logger, level in zip(libraries, levels):
            logger.setLevel(level)

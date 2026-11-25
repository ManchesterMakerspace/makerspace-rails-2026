from dataclasses import dataclass, field
from ipaddress import ip_address
import json
import os
import re
import socket


HDMI_CONNECTORS = {"auto": None, "0": "HDMI-A-1", "1": "HDMI-A-2"}


def hdmi_connector(port):
    try:
        return HDMI_CONNECTORS[port]
    except KeyError:
        raise ValueError("WELCOMEPI_HDMI_PORT must be auto, 0 or 1") from None


def parse_location_patterns(value):
    if value is None:
        return None
    try:
        patterns = json.loads(value)
    except json.JSONDecodeError as error:
        raise ValueError("WELCOMEPI_LOCATION_PATTERNS must be a JSON array of regex strings") from error
    if not isinstance(patterns, list) or any(not isinstance(pattern, str) for pattern in patterns):
        raise ValueError("WELCOMEPI_LOCATION_PATTERNS must be a JSON array of regex strings")
    try:
        return tuple(re.compile(pattern, re.IGNORECASE) for pattern in patterns)
    except (re.error, OverflowError) as error:
        raise ValueError(f"Invalid regex in WELCOMEPI_LOCATION_PATTERNS: {error}") from error


@dataclass(frozen=True)
class Settings:
    rails_uri: str = field(repr=False)
    ledger_uri: str = field(repr=False)
    mqtt_host: str
    mqtt_port: int
    mqtt_tls: bool
    mqtt_user: str | None
    mqtt_password: str | None = field(repr=False)
    mqtt_id: str
    nfc_port: str
    rotation: str
    opportunity_count: int
    organizations: tuple
    excluded: frozenset
    slack_token: str = field(repr=False)
    syslog_server: tuple[str, int] | None = None
    i2c_bus: str = "/dev/i2c-1"
    i2c_addresses: tuple[int, ...] = (0x24,)
    hdmi_port: str = "auto"
    location_patterns: tuple[re.Pattern[str], ...] | None = None

    def welcomes_location(self, location):
        return self.location_patterns is None or any(pattern.search(location) for pattern in self.location_patterns)

    @classmethod
    def load(cls, env=None):
        env = os.environ if env is None else env
        def required(key):
            if not env.get(key):
                raise ValueError(f"Missing {key}")
            return env[key]

        tls = env.get("MQTT_TLS", "true").lower()
        if tls not in ("true", "false"):
            raise ValueError("MQTT_TLS must be true or false")
        rotation = env.get("WELCOMEPI_ROTATION", "auto")
        if rotation not in ("auto", "normal", "left", "right"):
            raise ValueError("Invalid WELCOMEPI_ROTATION")
        hdmi_port = env.get("WELCOMEPI_HDMI_PORT", "auto")
        hdmi_connector(hdmi_port)
        count = int(env.get("WELCOMEPI_OPPORTUNITIES", "5"))
        if count < 1:
            raise ValueError("WELCOMEPI_OPPORTUNITIES must be positive")
        excluded = env.get("SLACKIDS_INELIGIBLE", "").strip() or "[]"
        if excluded.startswith("{") and excluded.endswith("}"):
            excluded = "[" + excluded[1:-1] + "]"
        ids = json.loads(excluded)
        if not isinstance(ids, list) or any(not isinstance(s, str) or not re.fullmatch("[UW][A-Z0-9]+", s)
                                           for s in ids):
            raise ValueError("Invalid SLACKIDS_INELIGIBLE")
        host = env.get("WELCOMEPI_SYSLOG_HOST", "").strip()
        port = env.get("WELCOMEPI_SYSLOG_PORT", "").strip()
        server = None
        if host or port:
            if not (host and port.isascii() and port.isdecimal() and 1 <= int(port) <= 65535):
                raise ValueError("Set both WELCOMEPI_SYSLOG_HOST and WELCOMEPI_SYSLOG_PORT (1–65535)")
            server = (str(ip_address(host)), int(port))
        bus = env.get("WELCOMEPI_I2C_BUS", "/dev/i2c-1")
        if not re.fullmatch(r"/dev/i2c-[0-9]+", bus):
            raise ValueError("WELCOMEPI_I2C_BUS must name a Linux /dev/i2c-N adapter")
        addresses = tuple(dict.fromkeys(int(addr.strip(), 0) for addr in
                                        env.get("WELCOMEPI_I2C_ADDRESSES", "0x24").split(",")))
        if not all(0x08 <= addr <= 0x77 for addr in addresses):
            raise ValueError("WELCOMEPI_I2C_ADDRESSES must contain usable 7-bit I2C addresses")
        return cls(required("MLAB_URI"), required("LEDGER_URI"), required("MQTT_HOST"),
                   int(env.get("MQTT_PORT", "8883" if tls == "true" else "1883")), tls == "true",
                   env.get("MQTT_USERNAME"), env.get("MQTT_PASSWORD"),
                   env.get("MQTT_CLIENT_ID") or "welcomepi-" + socket.gethostname(),
                   env.get("WELCOMEPI_NFC_PORT", "/dev/serial0"), rotation, count,
                   tuple(part.strip() for part in env.get("EVENTBRITE_ORGANIZATION_IDS", "").split(",") if part.strip()),
                   frozenset(ids), env.get("WELCOMEPI_SLACK_TOKEN", ""), server, bus, addresses, hdmi_port,
                   parse_location_patterns(env.get("WELCOMEPI_LOCATION_PATTERNS")))

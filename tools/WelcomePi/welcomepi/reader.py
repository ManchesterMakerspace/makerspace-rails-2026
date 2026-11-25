"""PN532 discovery and ISO 14443-A UID reads on Linux I2C or UART."""
from contextlib import closing
import errno
import logging
from pathlib import Path
import time


LOG = logging.getLogger(__name__)


class I2cTransport:
    """Expose the PN532's status-prefixed I2C frames to nfcpy's chipset driver."""
    def __init__(self, device):
        self.device = device
        self.expect_ack = True

    def write(self, frame):
        if self.device.write(frame) != len(frame):
            raise OSError("Short PN532 I2C write")
        self.expect_ack = True

    def read(self, timeout):
        deadline = time.monotonic() + timeout / 1000
        # A STOP can discard unread bytes. Read status and the entire frame
        # in one transaction. All UID-only responses with AutoRATS off fit in 64 bytes.
        length = 6 if self.expect_ack else 64
        while True:
            packet = self.device.read(1 + length)
            if len(packet) != 1 + length:
                raise OSError("Short PN532 I2C read")
            if packet[0] & 1:
                frame = bytearray(packet[1:])
                if self.expect_ack:
                    if frame != b"\x00\x00\xff\x00\xff\x00":
                        raise OSError("Invalid PN532 I2C acknowledgment")
                    self.expect_ack = False
                    return frame
                if frame[:3] != b"\x00\x00\xff" or frame[3] + 7 > length:
                    raise OSError("Invalid PN532 I2C response header")
                return frame[:frame[3] + 7]
            if time.monotonic() >= deadline:
                raise TimeoutError(errno.ETIMEDOUT, "PN532 I2C ready timeout")
            time.sleep(0.005)


class I2cReader:
    def __init__(self, bus, address):
        import fcntl
        from nfc.clf.pn532 import Chipset

        self.source = f"local PN532 I2C {bus}@0x{address:02x}"
        self.device = open(bus, "r+b", buffering=0)
        try:
            fcntl.ioctl(self.device.fileno(), 0x0703, address)  # Linux I2C_SLAVE, 7-bit address
            # Addressing the chip wakes it. Some breakouts NACK the first transaction.
            try:
                self.device.read(1)
            except OSError:
                time.sleep(0.01)
                self.device.read(1)
            self.chip = Chipset(I2cTransport(self.device), LOG)
            self.chip.sam_configuration("normal")
            version = self.chip.get_firmware_version()
            if len(version) != 4 or version[0] != 0x32:
                raise OSError("Firmware did not identify a PN532")
            self.chip.set_parameters(0)  # UID only, no automatic RATS/ATS exchange
            self.chip.rf_configuration(0x05, b"\x01\x00\x01")  # bounded passive activation
        except Exception:
            self.device.close()
            raise

    def read_uid(self):
        self.chip.rf_configuration(0x01, b"\x02")  # cycle the field to sense a held card again
        response = self.chip.in_list_passive_target(1, 0, b"")
        if response is None:
            return None
        if len(response) < 4 or response[3] not in (4, 7, 10) or len(response) < 4 + response[3]:
            raise OSError("Invalid PN532 Type A UID length")
        return response[4:4 + response[3]]

    def close(self):
        self.device.close()


class SerialReader:
    def __init__(self, port):
        import nfc

        tty = Path(port).resolve(strict=True).name
        if not tty.startswith("tty"):
            raise OSError(f"{port} does not resolve to a UART")
        self.source = f"local PN532 UART {port}"
        self.target = nfc.clf.RemoteTarget("106A")
        self.device = nfc.ContactlessFrontend("tty:" + tty[3:] + ":pn532")

    def read_uid(self):
        card = self.device.sense(self.target)
        return card.sdd_res if card is not None else None

    def close(self):
        self.device.close()


def discover_reader(settings):
    """Return an open reader and the provisioning result for the operator log."""
    from nfc.clf import Error
    from nfc.clf.pn532 import Chipset

    failures = []
    if Path(settings.i2c_bus).exists():
        for address in settings.i2c_addresses:
            try:
                reader = I2cReader(settings.i2c_bus, address)
            except (OSError, Chipset.Error) as error:
                failures.append(f"{settings.i2c_bus}@0x{address:02x} ({error})")
            else:
                return reader, f"PN532 ready on {reader.source}"
    else:
        failures.append(f"I2C adapter {settings.i2c_bus} unavailable")
    try:
        reader = SerialReader(settings.nfc_port)
    except (OSError, Error, Chipset.Error) as error:
        failures.append(f"UART {settings.nfc_port} ({error})")
        return None, "No PN532 found. Running MQTT-only. " + ", ".join(failures)
    return reader, f"PN532 ready on {reader.source} after I2C probe: " + ", ".join(failures)


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


def read_nfc(settings, emit, stop):
    from nfc.clf import Error
    from nfc.clf.pn532 import Chipset

    presence = CardPresence()
    previous = None
    while not stop.is_set():
        reader, report = discover_reader(settings)
        if report != previous:
            LOG.log(logging.INFO if reader else logging.WARNING, "%s", report)
            previous = report
        if reader:
            try:
                with closing(reader):
                    while not stop.is_set():
                        raw = reader.read_uid()
                        at = time.monotonic()
                        uid = presence.observe(raw.hex().upper() if raw else None, at)
                        if uid:
                            emit("scan", uid, True, at, reader.source)
                        stop.wait(0.08)
            except (OSError, Error, Chipset.Error) as error:
                LOG.warning("%s disconnected (%s). Probing again.", reader.source, error)
                previous = None
        stop.wait(3)

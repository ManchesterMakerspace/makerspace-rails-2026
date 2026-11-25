from collections import deque
from contextlib import ExitStack
import errno
import sys
import unittest
from unittest.mock import Mock, call, patch

from welcomepi.config import Settings
from welcomepi import reader


class ChipOnBus:
    """Emulate i2c-dev transactions, with real PN532 ACK, status, frames and checksums."""
    def __init__(self, chip_id=0x32):
        self.chip_id = chip_id
        self.replies = deque()
        self.targets = deque()
        self.closed = False

    def fileno(self):
        return 7

    def read(self, count):
        if count == 1:
            return b"\0"  # addressed for wake-up
        return self.replies.popleft().ljust(count, b"\xff")

    def write(self, frame):
        assert frame[:3] == b"\x00\x00\xff" and sum(frame[3:5]) % 256 == 0
        assert len(frame) == frame[3] + 7 and sum(frame[5:-1]) % 256 == 0
        command = frame[6]
        if command == 0x02:
            data = bytes((self.chip_id, 1, 6, 7))
        elif command == 0x4a:
            data = self.targets.popleft()
        else:
            assert (command, bytes(frame[7:-2])) in (
                (0x14, b"\x01\x00\x00"), (0x12, b"\x00"),
                (0x32, b"\x05\x01\x00\x01"), (0x32, b"\x01\x02"))
            data = b""
        body = bytes((0xd5, command + 1)) + data
        head = bytes((0, 0, 255, len(body), -len(body) % 256))
        self.replies.extend((b"\x00", b"\x01\x00\x00\xff\x00\xff\x00", b"\x00",
                             b"\x01" + head + body + bytes((-sum(body) % 256, 0))))
        return len(frame)

    def close(self):
        self.closed = True


class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.settings = Settings.load({"MLAB_URI": "test", "LEDGER_URI": "test", "MQTT_HOST": "broker",
                                       "WELCOMEPI_I2C_ADDRESSES": "0x24,0x25"})
        self.stack = self.enterContext(ExitStack())

    def bus(self, *chips):
        fcntl = Mock()
        self.stack.enter_context(patch.dict(sys.modules, fcntl=fcntl))
        self.stack.enter_context(patch("welcomepi.reader.Path.exists", return_value=True))
        self.stack.enter_context(patch("welcomepi.reader.open", side_effect=chips))
        return fcntl

    def test_firmware_probes_in_order_and_type_a_passes_real_nfcpy_decoder(self):
        other, chip = ChipOnBus(0x33), ChipOnBus()
        fcntl = self.bus(other, chip)
        with patch("welcomepi.reader.SerialReader") as uart:
            device, report = reader.discover_reader(self.settings)
        self.assertIn("I2C /dev/i2c-1@0x25", report)
        self.assertEqual(fcntl.ioctl.call_args_list, [call(7, 0x0703, 0x24), call(7, 0x0703, 0x25)])
        uart.assert_not_called()
        self.assertTrue(other.closed)
        for length in (4, 7, 10):
            uid = bytes(range(length))
            chip.targets.append(b"\x01\x01\x04\x00\x08" + bytes((length,)) + uid)
            self.assertEqual(device.read_uid(), uid)
        chip.targets.append(b"\0")
        self.assertIsNone(device.read_uid())
        chip.targets.append(b"\x01\x01\x04\x00\x08\x07\x00\x01")
        with self.assertRaisesRegex(OSError, "UID length"):
            device.read_uid()
        device.close()
        self.assertTrue(chip.closed)

    def test_enabled_bus_with_no_chip_or_disabled_bus_falls_back_to_uart(self):
        for enabled in (False, True):
            with self.subTest(enabled=enabled), patch("welcomepi.reader.Path.exists", return_value=enabled), \
                    patch("welcomepi.reader.I2cReader", side_effect=OSError("no ACK")) as probe, \
                    patch("welcomepi.reader.SerialReader") as serial:
                serial.return_value.source = "local PN532 UART /dev/serial0"
                device, report = reader.discover_reader(self.settings)
                self.assertIs(device, serial.return_value)
                self.assertIn("UART /dev/serial0", report)
                self.assertIn("no ACK" if enabled else "adapter /dev/i2c-1 unavailable", report)
                self.assertEqual(probe.call_count, 2 if enabled else 0)

    def test_uart_resolves_alias_and_preserves_bytes(self):
        with patch("welcomepi.reader.Path.resolve", return_value=reader.Path("/dev/ttyAMA0")), \
                patch("nfc.ContactlessFrontend") as frontend:
            device = reader.SerialReader("/dev/serial0")
            frontend.assert_called_once_with("tty:AMA0:pn532")
            frontend.return_value.sense.return_value.sdd_res = b"\x00\xab\x00\xde"
            self.assertEqual(device.read_uid(), b"\x00\xab\x00\xde")
            device.close()
            frontend.return_value.close.assert_called_once()

    def test_mqtt_only_warning_once_and_hotplug_recovers_with_one_event_for_held_card(self):
        stop, emit = Mock(), Mock()
        found = Mock(source="local PN532 UART /dev/serial0")
        found.read_uid.return_value = b"\x00\xab\x00\xde"
        stop.is_set.side_effect = (False, False, False, False, False, True, True)
        with patch("welcomepi.reader.Path.exists", return_value=False), \
                patch("welcomepi.reader.SerialReader", side_effect=[OSError("missing"), OSError("missing"), found]), \
                self.assertLogs("welcomepi.reader", level="INFO") as log:
            reader.read_nfc(self.settings, emit, stop)
        self.assertEqual([r.levelname for r in log.records], ["WARNING", "INFO"])
        self.assertIn("No PN532 found. Running MQTT-only", log.records[0].getMessage())
        self.assertIn("UART /dev/serial0", log.records[1].getMessage())
        emit.assert_called_once()
        kind, uid, local, _, source = emit.call_args.args
        self.assertEqual((kind, uid, local, source), ("scan", "00AB00DE", True, found.source))
        found.close.assert_called_once()

    def test_busy_chip_times_out_and_aborted_probe_closes_adapter(self):
        chip = Mock()
        chip.read.side_effect = lambda size: bytes(size)
        chip.write.side_effect = len
        self.bus(chip)
        with patch("welcomepi.reader.time.monotonic", side_effect=[0, 1]), \
                self.assertLogs("welcomepi.reader", level="ERROR"), self.assertRaises(OSError):
            reader.I2cReader("/dev/i2c-1", 0x24)
        chip.close.assert_called_once()
        with self.assertRaises(TimeoutError) as failure:
            reader.I2cTransport(chip).read(0)
        self.assertEqual(failure.exception.errno, errno.ETIMEDOUT)

from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

from pi0 import check, configure_boot
from welcomepi.config import Settings


class BootProfile(unittest.TestCase):
    def test_first_install_backups_and_repeated_install(self):
        with TemporaryDirectory() as folder, redirect_stdout(StringIO()):
            root = Path(folder)
            config = root / "config.txt"
            cmdline = root / "cmdline.txt"
            config.write_bytes(b"# Pi boot\r\n[pi4]\r\ndtoverlay=vc4-kms-v3d,cma-128\r\n[all]\r\nenable_uart=0\r\n")
            cmdline.write_bytes(b'console=tty1 root=PARTUUID=abcd-02 rootwait console=serial0,115200 '
                                b'test="keep  console=ttyS0 here" video=DSI-1:800x480 '
                                b'consoleblank=600 video=HDMI-A-1:1920x1080@60 console=ttyS0\r\n')
            originals = {p: p.read_bytes() for p in (config, cmdline)}
            configure_boot.configure(root)
            self.assertIn("\n[all]\ndtoverlay=vc4-kms-v3d\nenable_uart=1\ndisable_fw_kms_setup=1\n", config.read_text())
            self.assertEqual(cmdline.read_text(),
                'console=tty1 root=PARTUUID=abcd-02 rootwait test="keep  console=ttyS0 here" '
                'video=DSI-1:800x480 video=HDMI-A-1:1280x720@60 consoleblank=0\n')
            first = {p: p.read_bytes() for p in originals}
            configure_boot.configure(root)
            for path, original in originals.items():
                self.assertEqual(path.read_bytes(), first[path])
                self.assertEqual(path.with_suffix(".txt.welcomepi-backup").read_bytes(), original)

    def test_stock_overlay_and_unrelated_boot_settings_survive(self):
        original = "dtparam=audio=on\ndtoverlay=vc4-kms-v3d,cma-64\ndisable_fw_kms_setup=1\n[cm4]\notg_mode=1\n[all]\n"
        result = configure_boot.firmware_config(original)
        self.assertTrue(result.startswith(original))
        self.assertEqual(result.count("dtoverlay="), 1)
        self.assertEqual(result.count("disable_fw_kms_setup=1"), 1)
        self.assertEqual(result, configure_boot.firmware_config(result))

    def test_invalid_cmdline_leaves_both_files_intact(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "config.txt").write_bytes(b"enable_uart=0\n")
            (root / "cmdline.txt").write_bytes(b"root=PARTUUID=a\nconsole=tty1\n")
            before = {p: p.read_bytes() for p in root.iterdir()}
            with self.assertRaises(ValueError):
                configure_boot.configure(root)
            self.assertEqual(before, {p: p.read_bytes() for p in root.iterdir()})


class Commissioning(unittest.TestCase):
    def setUp(self):
        self.settings = Settings.load({"MLAB_URI": "test", "LEDGER_URI": "test", "MQTT_HOST": "broker",
                                       "MQTT_CLIENT_ID": "live-kiosk"})

    def test_watcher_uses_separate_client_and_omits_identity(self):
        client = Mock()
        def subscribe(settings, emit):
            self.assertNotEqual(settings.mqtt_id, self.settings.mqtt_id)
            self.assertTrue(settings.mqtt_id.startswith("wpi-check-"))
            emit("subscribed")
            emit("change", "members", "update", {"firstname": "Private name"})
            emit("scan", "00FA0001", False, 10)
            return client
        output = StringIO()
        with patch.object(check, "start_mqtt", side_effect=subscribe), redirect_stdout(output):
            check.probe_mqtt(self.settings, watch=True)
        self.assertIn("Received a fresh checkins/insert", output.getvalue())
        self.assertNotIn("00FA0001", output.getvalue())
        self.assertNotIn("Private name", output.getvalue())
        client.disconnect.assert_called_once()
        client.loop_stop.assert_called_once()

    def test_refused_subscription_fails_and_closes(self):
        client = Mock()
        def refused(settings, emit):
            emit("disconnected")
            return client
        with patch.object(check, "start_mqtt", side_effect=refused), self.assertRaises(check.CheckFailed):
            check.probe_mqtt(self.settings, watch=False)
        client.disconnect.assert_called_once()
        client.loop_stop.assert_called_once()

    def test_active_service_keeps_uart_and_database_errors_are_redacted(self):
        output = StringIO()
        with patch("sys.argv", ["check", "check", "--reader-in-use"]), \
                patch.object(Settings, "load", return_value=self.settings), \
                patch.object(check, "probe_reader") as reader, patch.object(check, "probe_mqtt") as mqtt, \
                patch.object(check, "read_collections", side_effect=ValueError("secret URI")), \
                redirect_stderr(output), redirect_stdout(output):
            self.assertEqual(check.main(), 1)
        reader.assert_not_called()
        mqtt.assert_called_once()
        self.assertNotIn("secret URI", output.getvalue())

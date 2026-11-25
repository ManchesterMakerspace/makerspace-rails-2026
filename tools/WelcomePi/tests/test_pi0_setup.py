from contextlib import redirect_stderr, redirect_stdout
from dataclasses import replace
from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from pi0 import check, configure_boot
from welcomepi.config import Settings


class BootProfile(unittest.TestCase):
    def test_supported_board_models_and_os_images(self):
        models = (("Raspberry Pi Zero W Rev 1.1\0", "armhf", "pi0w"),
                  ("Raspberry Pi 4 Model B Rev 1.5\0", "armhf", "pi4"),
                  ("Raspberry Pi 4 Model B Rev 1.5\0", "arm64", "pi4"),
                  ("Raspberry Pi 5 Model B Rev 1.0\0", "arm64", "pi5"),
                  ("Raspberry Pi 5\0", "arm64", "pi5"))
        for model, arch, board in models:
            for codename in ("bookworm", "trixie"):
                with self.subTest(model=model, architecture=arch, codename=codename):
                    self.assertEqual(configure_boot.board_profile(model, codename, arch), board)
        unsupported = (("Raspberry Pi 400 Rev 1.0", "bookworm", "arm64"),
                       ("Raspberry Pi 500 Rev 1.0", "bookworm", "arm64"),
                       ("Raspberry Pi 5", "bookworm", "armhf"),
                       ("Raspberry Pi 5", "trixie", "armhf"),
                       ("Raspberry Pi 5", "bullseye", "arm64"))
        for values in unsupported:
            with self.subTest(platform=values), self.assertRaises(ValueError):
                configure_boot.board_profile(*values)

    def test_dual_hdmi_profiles_preserve_port_modes_and_configure_header_uart(self):
        original = ("[pi4]\ndtoverlay=vc4-fkms-v3d-pi4,cma-128\n"
                    "[pi5]\ndtoverlay=vc4-kms-v3d-pi5\n[all]\n")
        video = "video=HDMI-A-2:1920x1080@60,rotate=90 video=HDMI-A-1:d"
        cmdline = f"rootwait console=serial0,115200 console=ttyAMA0,9600 {video} consoleblank=600\n"
        for board in ("pi4", "pi5"):
            with self.subTest(board=board):
                config = configure_boot.firmware_config(original, board)
                self.assertEqual(config, configure_boot.firmware_config(config, board))
                self.assertEqual(config.count("vc4-"), 2)
                self.assertIn("disable_fw_kms_setup=1", config)
                kernel = configure_boot.kernel_cmdline(cmdline, board)
                self.assertEqual(kernel, configure_boot.kernel_cmdline(kernel, board))
                self.assertIn(video, kernel)
                self.assertNotIn("video=", configure_boot.kernel_cmdline("rootwait", board))
                self.assertNotIn("console=ttyAMA0", kernel)
                self.assertTrue(kernel.endswith("consoleblank=0\n"))
                if board == "pi5":
                    self.assertIn("[pi4]\ndtoverlay=vc4-fkms-v3d-pi4,cma-128", config)
                    self.assertIn("[pi5]\ndtoverlay=uart0-pi5", config)
                    self.assertIn("console=serial0,115200", kernel)
                else:
                    self.assertIn("[pi4]\ndtoverlay=vc4-kms-v3d-pi4,cma-128", config)
                    self.assertIn("enable_uart=1", config)
                    self.assertNotIn("uart0-pi5", config)
                    self.assertNotIn("console=serial0", kernel)

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
            emit("checkin", SimpleNamespace(location="Test door", uid="00FA0001"), 10,
                 "activity/checkins/activeMember/Reader01", True)
            return client
        output = StringIO()
        with patch.object(check, "start_mqtt", side_effect=subscribe), redirect_stdout(output):
            check.probe_mqtt(self.settings, watch=True)
        self.assertIn(f"all {len(check.TOPICS)} kiosk subscriptions", output.getvalue())
        self.assertIn("Received a fresh door check-in from a matching location", output.getvalue())
        self.assertIn("activity/checkins/activeMember/Reader01", output.getvalue())
        self.assertIn("eligible member's agenda", output.getvalue())
        self.assertNotIn("00FA0001", output.getvalue())
        self.assertNotIn("Private name", output.getvalue())
        client.disconnect.assert_called_once()
        client.loop_stop.assert_called_once()

    def test_watcher_explains_how_to_open_agenda_after_name_only_record(self):
        def subscribe(settings, emit):
            emit("subscribed")
            emit("checkin", SimpleNamespace(location="Test door", uid="", name="Sample Member"), 10,
                 "activity/checkins/Reader02", True)
            return Mock()
        output = StringIO()
        with patch.object(check, "start_mqtt", side_effect=subscribe), redirect_stdout(output):
            check.probe_mqtt(self.settings, watch=True)
        self.assertIn("large first-name greeting", output.getvalue())
        self.assertIn("fresh check-in or local tap supplies an eligible card UID", output.getvalue())
        self.assertIn("activity/checkins/Reader02", output.getvalue())
        self.assertNotIn("Sample Member", output.getvalue())
        self.assertNotIn("member's agenda", output.getvalue())

    def test_watcher_waits_past_historical_or_filtered_events(self):
        config = Settings.load({"MLAB_URI": "test", "LEDGER_URI": "test", "MQTT_HOST": "broker",
                                "WELCOMEPI_LOCATION_PATTERNS": '["^test door$"]'})
        def subscribe(settings, emit):
            emit("subscribed")
            emit("checkin", SimpleNamespace(location="Test door"), 10, "checkins/insert", False)
            emit("checkin", SimpleNamespace(location="Another door"), 11, "checkins/insert", True)
            emit("disconnected")
            return Mock()
        with patch.object(check, "start_mqtt", side_effect=subscribe), redirect_stdout(StringIO()), \
                self.assertRaises(check.CheckFailed):
            check.probe_mqtt(config, watch=True)

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
        settings = replace(self.settings, hdmi_port="1")
        with patch("sys.argv", ["check", "check", "--reader-in-use"]), \
                patch.object(Settings, "load", return_value=settings), \
                patch.object(check, "connected_hdmi", return_value="card2-HDMI-A-2") as hdmi, \
                patch.object(check, "probe_reader") as reader, patch.object(check, "probe_mqtt") as mqtt, \
                patch.object(check, "read_collections", side_effect=ValueError("secret URI")), \
                redirect_stderr(output), redirect_stdout(output):
            self.assertEqual(check.main(), 1)
        reader.assert_not_called()
        hdmi.assert_called_once_with("1")
        self.assertIn("selected HDMI1): connected on card2-HDMI-A-2", output.getvalue())
        mqtt.assert_called_once()
        self.assertNotIn("secret URI", output.getvalue())

from datetime import datetime
from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from urllib.request import Request

from PIL import Image, ImageDraw

from welcomepi.config import Settings
from welcomepi.display import Display, Output, orientation, scanout
from welcomepi.ledger import Avatar, Details, PrivateFileRedirect, fetch_avatar
from welcomepi.render import Canvas, font, qr_image, qr_modules, render, section_pages, wrap
from welcomepi.state import HOME, Identity, Screen, UTC


class Layout(unittest.TestCase):
    now = datetime(2026, 11, 23, 3, tzinfo=UTC)

    def test_first_greeting_fits_the_full_name_on_landscape_and_portrait_displays(self):
        for size, first in (((1280, 720), "I"), ((320, 240), "Alexandria"),
                            ((320, 480), "María José"), ((480, 320), "W" * 64)):
            with self.subTest(size=size, first=first):
                screen = Screen(0)
                screen.show("agenda", 0, Identity(1, 2, "01", first, "member", 10**15))
                draw_name = ImageDraw.ImageDraw.multiline_text
                with patch.object(ImageDraw.ImageDraw, "multiline_text", autospec=True, side_effect=draw_name) as drawn:
                    image, count = render(size, screen, self.now, {})
                self.assertEqual((image.size, count), (size, 1))
                draw, xy, text = drawn.call_args.args
                face = drawn.call_args.kwargs["font"]
                spacing = drawn.call_args.kwargs["spacing"]
                self.assertEqual("".join(text.split()), first.replace(" ", "") + "!")
                left, top, right, bottom = draw.multiline_textbbox(xy, text, font=face, spacing=spacing, align="center")
                canvas = Canvas(size)
                self.assertGreaterEqual(min(left, top), canvas.pad)
                self.assertLessEqual(right, size[0] - canvas.pad)
                self.assertLessEqual(bottom, size[1] - 2 * canvas.pad - canvas.small.size)
                if first == "I":
                    self.assertGreater(bottom - top, size[1] // 2)
                elif first == "Alexandria":
                    self.assertGreater(font(face.size + 1, True).getbbox(text)[2], canvas.width)
                else:
                    self.assertIn("\n", text)

    def test_large_greeting_changes_to_compact_header_with_loaded_agenda(self):
        screen = Screen(0)
        screen.show("agenda", 0, Identity(1, 2, "01", "Sam", "member", 10**15))
        size = (720, 1280)
        with patch.object(ImageDraw.ImageDraw, "multiline_text", autospec=True) as initial:
            render(size, screen, self.now, {"events": []})
        with patch.object(Canvas, "text", autospec=True) as agenda:
            render(size, screen, self.now, {"reservations": [("Wood shop", "9 AM")]})
        headline = next(c for c in agenda.call_args_list if c.args[3] == "Welcome, Sam!")
        self.assertGreater(initial.call_args.kwargs["font"].size, 2 * headline.args[4].size)
        self.assertTrue(any("Wood shop" in c.args[3] for c in agenda.call_args_list))

    def test_record_only_greeting_uses_the_first_name_and_full_size_layout(self):
        screen = Screen(0)
        screen.greet_record("River Example", 1)
        with patch.object(Canvas, "greeting", autospec=True) as greeting:
            _, pages = render((800, 480), screen, self.now, {})
        self.assertEqual(greeting.call_args.args[1], "River")
        self.assertEqual(pages, 1)

    def test_greeting_supports_legacy_and_oversized_first_names(self):
        for first, expected in ((42, "42!"), ("  ", "member!"), ("A " * 1000, "…!")):
            with self.subTest(expected=expected):
                screen = Screen(0)
                screen.show("agenda", 0, Identity(1, 2, "01", first, "member", 10**15))
                with patch.object(ImageDraw.ImageDraw, "multiline_text", autospec=True) as painted:
                    render((320, 240), screen, self.now, {})
                self.assertTrue(painted.call_args.args[2].endswith(expected))

    def test_board_has_intact_qr_on_every_page(self):
        board = {"recent": [(f"First{i}", "8:15 PM") for i in range(5)],
                 "leaders": [(f"Member {i}.", "32 pts") for i in range(10)],
                 "opportunities": [(f"Weekly task {i}", "2 pts") for i in range(10)]}
        for wh in [(320, 240), (480, 320), (320, 480), (1280, 720), (720, 1280), (1920, 1080)]:
            with self.subTest(size=wh):
                count = render(wh, Screen(0), self.now, board)[1]
                if wh in ((1280, 720), (1920, 1080)):
                    self.assertEqual(count, 1)
                if wh == (480, 320):
                    self.assertGreater(count, 1)
                for p in range(count):
                    image, _ = render(wh, Screen(0), self.now, board, p)
                    # White occurs only in the header title/QR; locate the QR
                    # square from its clean top-right quiet zone.
                    w, h = wh
                    x = next(x for x in range(w-1, w//2, -1)
                             if any(image.getpixel((x,y)) == (255,255,255) for y in range(h//4)))
                    y = next(y for y in range(h//4) if image.getpixel((x, y)) == (255,255,255))
                    left = x
                    while left > 0 and image.getpixel((left-1, y)) == (255,255,255):
                        left -= 1
                    size = x-left+1
                    expected = qr_image(size)
                    self.assertIsNotNone(expected)
                    self.assertEqual(image.crop((left, y, x+1, y+size)).tobytes(), expected.tobytes())

    def test_required_rows_survive_on_a_short_display(self):
        names = [f"Person{i}" for i in range(5)]
        leaders = [(f"Leader{i}", "1 pt") for i in range(10)]
        jobs = [(f"Task{i}", "2 pts") for i in range(10)]
        board = {"recent": [(name, "8:15 PM") for name in names], "leaders": leaders, "opportunities": jobs}
        size = (320, 240)
        with patch.object(Canvas, "text", autospec=True) as printed:
            count = render(size, Screen(0), self.now, board)[1]
            for page in range(1, count):
                render(size, Screen(0), self.now, board, page)
        lines = []
        for call in printed.call_args_list:
            _, x, y, line, face, *_ = call.args
            self.assertLessEqual(y + face.size, size[1])
            self.assertLessEqual(x + face.getlength(line), size[0])
            lines.append(line)
        text = " ".join(lines)
        for name in names + [row[0] for row in leaders + jobs]:
            self.assertIn(name, text)

    def test_only_complete_optional_sections_use_free_agenda_space(self):
        member = Identity(1, 2, "01", "Test", "member", 10**15)
        s = Screen(0)
        s.show("agenda", 5, member)
        data = {"reservations": [], "opportunities": [], "events": []}
        with patch("welcomepi.render.qr_image", wraps=qr_image) as qr:
            render((800, 480), s, self.now, data)
            self.assertGreaterEqual(qr.call_args.args[0], 3*qr_modules().width)
            qr.reset_mock()
            data["opportunities"] = [(f"Sort workshop materials {i}", "1 pt") for i in range(80)]
            _, count = render((480, 320), s, self.now, data)
            self.assertGreater(count, 1)
            qr.assert_not_called()

    def test_all_private_text_survives_wrapping_and_pagination(self):
        text = "A long thank you for your time and effort " * 20
        sections = [("Kudos received", [(text, "")]), ("Current checkouts", [("Lathe", "")])]
        face = font(16)
        pages = section_pages(sections, face, 225, 5)
        self.assertTrue(all(len(page) <= 5 for page in pages))
        lines = [line for page in pages for kind, line in page if kind == "text"]
        self.assertEqual(" ".join(lines), text.strip() + " Lathe")
        self.assertTrue(all(face.getlength(line) <= 225 for line in wrap("W"*100, face, 225)))
        s = Screen(0)
        s.show("details", 5, Identity(1, 2, "01", "Test", "member", 10**15))
        for thumbnail in [None, Image.new("RGB", (512, 512), "red")]:
            image, count = render((480, 320), s, self.now, {"details": Details(sections, 2), "avatar": thumbnail})
            self.assertEqual(image.size, (480, 320))
            self.assertGreater(count, 1)


class Hardware(unittest.TestCase):
    def monitors(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.enterContext(patch.dict("sys.modules", pykms=Mock()))
        self.enterContext(patch("welcomepi.display.DRM_CLASS", root))
        self.output = self.enterContext(patch("welcomepi.display.Output"))
        paths = [root / ("card2-" + name) / "status" for name in ("HDMI-A-1", "HDMI-A-2")]
        for status in paths:
            status.parent.mkdir()
            status.write_text("connected\n")
        return paths

    def test_hdmi_port_setting(self):
        env = {"MLAB_URI": "test", "LEDGER_URI": "test", "MQTT_HOST": "broker"}
        self.assertEqual(Settings.load(env).hdmi_port, "auto")
        for port in ("auto", "0", "1"):
            self.assertEqual(Settings.load({**env, "WELCOMEPI_HDMI_PORT": port}).hdmi_port, port)
        for port in ("2", "", "HDMI-A-1", "*"):
            with self.assertRaisesRegex(ValueError, "WELCOMEPI_HDMI_PORT"):
                Settings.load({**env, "WELCOMEPI_HDMI_PORT": port})

    def test_dual_hdmi_selection_disconnect_and_reconnect(self):
        first, second = self.monitors()
        for port, name, status in (("auto", "HDMI-A-1", first), ("0", "HDMI-A-1", first), ("1", "HDMI-A-2", second)):
            with self.subTest(port=port), self.assertLogs("welcomepi.display.cable", "INFO") as logs:
                display = Display("left", port)
                self.assertTrue(display.probe(0))
                self.output.assert_called_once_with(display.kms, "/dev/dri/card2", name, "left")
                self.output.reset_mock()
                status.write_text("disconnected\n")
                self.assertTrue(display.probe(2))
                if port == "auto":
                    self.output.assert_called_once_with(display.kms, "/dev/dri/card2", "HDMI-A-2", "left")
                    self.output.reset_mock()
                else:
                    self.assertIsNone(display.output)
                    self.assertFalse(display.probe(4))
                    self.output.assert_not_called()
                status.write_text("connected\n")
                self.assertTrue(display.probe(6))
                self.output.assert_called_once_with(display.kms, "/dev/dri/card2", name, "left")
                self.output.reset_mock()
                self.assertEqual([r.levelname for r in logs.records], ["WARNING", "INFO"])
                self.assertTrue(all(name in r.getMessage() for r in logs.records))

    def test_missing_preferred_port_at_startup_and_recovery_are_reported_once(self):
        _, selected = self.monitors()
        selected.write_text("disconnected\n")
        display = Display("auto", "1")
        with self.assertLogs("welcomepi.display.cable", "INFO") as logs:
            self.assertFalse(display.probe(0))
            self.assertFalse(display.probe(2))
            selected.write_text("connected\n")
            self.assertTrue(display.probe(4))
            self.assertFalse(display.probe(6))
        loss, recovery = logs.records
        self.assertEqual(loss.levelname, "WARNING")
        self.assertIn("Preferred HDMI1 (HDMI-A-2) is disconnected. Check the HDMI cable", loss.getMessage())
        self.assertEqual(recovery.levelname, "INFO")
        self.assertIn("Preferred HDMI1 (HDMI-A-2) HDMI cable connection restored", recovery.getMessage())

    def test_auto_tracks_lost_connector_across_close_and_failover(self):
        first, second = self.monitors()
        first.write_text("disconnected\n")
        display = Display("auto")
        with self.assertNoLogs("welcomepi.display.cable", "INFO"):
            self.assertTrue(display.probe(0))
            display.close()  # Simulate a failed frame submission before the next poll.
        first.write_text("connected\n")
        second.write_text("disconnected\n")
        with self.assertLogs("welcomepi.display.cable", "INFO") as logs:
            self.assertTrue(display.probe(2))
            self.assertEqual(display.port, "card2-HDMI-A-1")
            second.write_text("connected\n")
            self.assertFalse(display.probe(4))  # HDMI1 recovered while HDMI0 remains in use.
        loss, recovery = logs.records
        self.assertIn("HDMI1 (HDMI-A-2) is disconnected", loss.getMessage())
        self.assertIn("HDMI1 (HDMI-A-2) HDMI cable connection restored", recovery.getMessage())

    def test_cloned_or_unassigned_hdmi_only_uses_an_independent_crtc_and_plane(self):
        shared, spare = SimpleNamespace(id=10), SimpleNamespace(id=11)
        selected, other = Mock(id=1), Mock(id=2)
        other.get_prop_value.return_value = shared.id
        selected.get_possible_crtcs.return_value = [shared, spare]
        def primary(owner):
            plane = Mock()
            plane.get_prop_value.side_effect = {"type": 1, "CRTC_ID": owner}.__getitem__
            return plane
        busy_plane, free_plane, current_plane = primary(shared.id), primary(0), primary(spare.id)
        card = SimpleNamespace(connectors=[selected, other], planes=[busy_plane, free_plane, current_plane])
        for active in (shared, None):
            self.assertEqual(scanout(card, selected, active), (spare, current_plane))
        card.planes.remove(current_plane)
        self.assertEqual(scanout(card, selected, None), (spare, free_plane))
        card.planes.remove(free_plane)
        with self.assertRaises(OSError):
            scanout(card, selected, None)

    def test_standby_keeps_restore_mode_until_hotplug_returns(self):
        _, selected = self.monitors()
        with self.assertNoLogs("welcomepi.display.cable", "INFO"):
            display = Display("auto", "1")
            self.assertTrue(display.probe(0))
            old = display.output
            old.active = False
            selected.write_text("disconnected\n")  # HDMI0 remains connected throughout.
            self.assertFalse(display.probe(2))
            self.assertIs(display.output, old)
            old.active = True  # The wake frame was submitted with the stored mode.
            self.assertFalse(display.probe(4))
            selected.write_text("connected\n")
            self.assertTrue(display.probe(6))
            self.assertEqual(self.output.call_count, 2)
            self.assertTrue(all(c.args[2] == "HDMI-A-2" for c in self.output.call_args_list))
            old.close.assert_called_once()

    def test_auto_does_not_switch_to_second_monitor_in_standby(self):
        first, _ = self.monitors()
        with self.assertNoLogs("welcomepi.display.cable", "INFO"):
            display = Display("auto")
            self.assertTrue(display.probe(0))
            display.output.active = False
            first.write_text("disconnected\n")
            self.assertFalse(display.probe(2))
            self.output.assert_called_once_with(display.kms, "/dev/dri/card2", "HDMI-A-1", "auto")
            display.output.active = True
            self.assertFalse(display.probe(4))  # Give a sleeping monitor time to reassert hotplug.
        with self.assertLogs("welcomepi.display.cable", "WARNING") as logs:
            self.assertTrue(display.probe(6))
            self.assertEqual(display.port, "card2-HDMI-A-2")
        self.assertIn("HDMI0 (HDMI-A-1) is disconnected", logs.records[0].getMessage())

    def test_rotation_metadata_and_override(self):
        conn = "HDMI-A-1"
        self.assertEqual(orientation("auto", conn, 2, 1, "", ""), 90)
        self.assertEqual(orientation("auto", conn, 3, 1, "", ""), 270)
        self.assertEqual(orientation("auto", conn, None, 1, "video=HDMI-A-1:800x600,rotate=270", ""), 270)
        self.assertEqual(orientation("auto", conn, None, 1, "video=HDMI-A-2:800x600,rotate=270", "3"), 90)
        self.assertEqual(orientation("auto", conn, None, 8, "", ""), 270)
        self.assertEqual(orientation("normal", conn, 2, 2, "", ""), 0)
        self.assertEqual(orientation("right", conn, 2, 2, "", ""), 270)

    def test_padded_xrgb_frame_rotated_once_and_fresh_frame_before_wake(self):
        mode = SimpleNamespace(hdisplay=3, vdisplay=2, to_blob=lambda c: SimpleNamespace(id=7))
        crtc = SimpleNamespace(id=11, mode=mode)
        conn = Mock(id=12, fullname="HDMI-A-1")
        conn.get_current_crtc.return_value = crtc
        conn.get_possible_crtcs.return_value = [crtc]
        conn.has_prop.return_value = False
        plane = Mock()
        plane.get_prop_value.side_effect = {"type": 1, "CRTC_ID": crtc.id, "rotation": 1}.__getitem__
        card = SimpleNamespace(connectors=[conn], planes=[plane])
        files, requests = [], []
        def framebuffer(card, w, h, fourcc):
            self.assertEqual(fourcc, "XR24")
            f = tempfile.TemporaryFile()
            self.addCleanup(f.close)
            f.truncate(16*h)
            files.append(f)
            return SimpleNamespace(fd=lambda p: f.fileno(), stride=lambda p: 16)
        def request(card):
            req = Mock()
            req.commit_sync.return_value = 0
            requests.append(req)
            return req
        kms = SimpleNamespace(Card=lambda _: card, DumbFramebuffer=framebuffer, AtomicReq=request)
        with patch("welcomepi.display.read_text", return_value=""):
            output = Output(kms, "device", conn.fullname, "right")
        self.addCleanup(output.close)
        self.assertEqual(output.size, (2, 3))
        image = Image.new("RGB", (2, 3), "red")
        image.putpixel((0, 0), (0, 100, 255))
        output.present(image)
        self.assertEqual(output.maps[0][:], image.transpose(Image.Transpose.ROTATE_270).tobytes("raw", "BGRX", 16, 1))
        requests[-1].add.assert_any_call(plane, "rotation", 1)
        output.standby()
        requests[-1].add.assert_any_call(crtc, {"MODE_ID": 0, "ACTIVE": 0})
        output.present(Image.new("RGB", (2, 3), "green"))
        requests[-1].commit_sync.assert_called_once_with(allow_modeset=True)
        self.assertNotEqual(output.maps[0][:], output.maps[1][:])


class PrivateImage(unittest.TestCase):
    def test_authenticated_jpeg_decode_hash_and_host(self):
        out = BytesIO()
        Image.new("RGB", (512, 512), "orange").save(out, format="JPEG")
        data = out.getvalue()
        file = {"id": "F1", "mimetype": "image/jpeg", "url_private_download": "https://files.slack.com/private"}
        ref = Avatar("F1", "r1", sha256(data).hexdigest())
        with patch("welcomepi.ledger.build_opener") as build:
            fetch = build.return_value.open
            fetch.side_effect = [BytesIO(json.dumps({"ok": True, "file": file}).encode()), BytesIO(data)]
            image = fetch_avatar("test-token", ref)
            self.assertEqual(image.size, (512, 512))
            self.assertTrue(all(call.args[0].get_header("Authorization") == "Bearer test-token" for call in fetch.call_args_list))
            file["url_private_download"] = "https://example.invalid/private"
            fetch.side_effect = [BytesIO(json.dumps({"ok": True, "file": file}).encode())]
            self.assertIsNone(fetch_avatar("test-token", ref))
        redirect = PrivateFileRedirect()
        self.assertIsNone(redirect.redirect_request(Request("https://files.slack.com/private"),
                          None, 302, "", {}, "https://example.invalid/"))

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

from PIL import Image

from welcomepi.display import Display, Output, orientation
from welcomepi.ledger import Avatar, Details, PrivateFileRedirect, fetch_avatar
from welcomepi.render import Canvas, font, qr_image, qr_modules, render, section_pages, wrap
from welcomepi.state import HOME, Identity, Screen, UTC


class Layout(unittest.TestCase):
    now = datetime(2026, 11, 23, 3, tzinfo=UTC)

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
    def test_standby_keeps_restore_mode_until_hotplug_returns(self):
        path = Path("/sys/class/drm/card0-HDMI-A-1/status")
        with patch.dict("sys.modules", pykms=Mock()), patch.object(Path, "glob", return_value=[path]), \
                patch("welcomepi.display.read_text") as status, patch("welcomepi.display.Output") as output:
            display = Display("auto")
            status.return_value = "connected"
            self.assertTrue(display.probe(0))
            old = display.output
            old.active = False
            status.return_value = "disconnected"
            self.assertFalse(display.probe(2))
            self.assertIs(display.output, old)
            old.active = True  # The wake frame was submitted with the stored mode.
            self.assertFalse(display.probe(4))
            status.return_value = "connected"
            self.assertTrue(display.probe(6))
            self.assertEqual(output.call_count, 2)
            old.close.assert_called_once()

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
        conn.has_prop.return_value = False
        plane = Mock()
        plane.get_prop_value.side_effect = lambda name: 1
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

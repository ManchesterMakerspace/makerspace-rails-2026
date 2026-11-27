from datetime import datetime
from hashlib import sha256
from io import BytesIO
from itertools import product
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from urllib.request import Request

from PIL import Image, ImageColor, ImageDraw

from welcomepi.config import Settings
from welcomepi.display import Display, Output, orientation, scanout
from welcomepi.ledger import Avatar, Details, PrivateFileRedirect, fetch_avatar
from welcomepi.render import BoardQR, Canvas, font, qr_image, qr_modules, render, section_pages, wrap
from welcomepi.state import HOME, Identity, Screen, UTC


class Layout(unittest.TestCase):
    now = datetime(2026, 11, 23, 3, tzinfo=UTC)

    def test_asymmetric_insets_reflow_the_board_in_viewer_coordinates(self):
        for w, h in ((800, 480), (480, 800)):
            inset = (5, 19, 31, 8)
            size = (w - 36, h - 27)
            expected, count = render(size, Screen(0), self.now, {}, variant=2, dimmed=True)
            frame, pages = render((w, h), Screen(0), self.now, {}, variant=2, dimmed=True, insets=inset)
            box = (5, 19, w - 31, h - 8)
            self.assertEqual((frame.size, frame.getbbox(), pages), ((w, h), box, count))
            self.assertEqual(frame.crop(box).tobytes(), expected.tobytes())
            self.assert_intact_qr(frame.crop(box), dimmed=True)
        with self.assertRaisesRegex(ValueError, "no visible area"):
            render((800, 480), Screen(0), self.now, {}, insets=(400, 0, 400, 0))

    def test_font_stroke_thickens_text_and_preserves_the_board_qr(self):
        canvas = Canvas((320, 240))
        heavy = Canvas((320, 240), stroke=1)
        for target in (canvas, heavy):
            target.text(20, 20, "Recent check-ins", target.body)
        ink = ImageColor.getrgb(canvas.palette.ink)
        def ink_pixels(image):
            return sum(count for count, color in image.getcolors(320 * 240) if color == ink)
        self.assertGreater(ink_pixels(heavy.image), ink_pixels(canvas.image))
        image, _ = render((800, 480), Screen(0), self.now, {}, stroke=1)
        self.assert_intact_qr(image, dimmed=False)

    def test_first_greeting_fits_the_full_name_on_landscape_and_portrait_displays(self):
        cases = [((1280, 720), "I"), ((320, 240), "Alexandria"),
                 ((320, 480), "María José"), ((480, 320), "W" * 64)]
        for (size, first), variant in product(cases, range(4)):
            with self.subTest(size=size, first=first, variant=variant):
                screen = Screen(0)
                screen.show("agenda", 0, Identity(1, 2, "01", first, "member", 10**15))
                draw_name = ImageDraw.ImageDraw.multiline_text
                with patch.object(ImageDraw.ImageDraw, "multiline_text", autospec=True, side_effect=draw_name) as drawn:
                    image, count = render(size, screen, self.now, {}, variant=variant)
                self.assertEqual((image.size, count), (size, 1))
                draw, xy, text = drawn.call_args.args
                face = drawn.call_args.kwargs["font"]
                spacing = drawn.call_args.kwargs["spacing"]
                background = sum(image.getpixel((0, 0)))
                name_ink = sum(ImageColor.getrgb(drawn.call_args.kwargs["fill"]))
                self.assertEqual(background > name_ink, variant % 2 == 0)
                self.assertEqual("".join(text.split()), first.replace(" ", "") + "!")
                left, top, right, bottom = draw.multiline_textbbox(xy, text, font=face, spacing=spacing, align="center")
                canvas = Canvas(size)
                self.assertGreaterEqual(min(left, top), canvas.pad)
                self.assertLessEqual(right, size[0] - canvas.pad)
                if variant % 2:
                    self.assertGreaterEqual(top, 2 * canvas.pad + canvas.small.size)
                    self.assertLessEqual(bottom, size[1] - canvas.pad)
                else:
                    self.assertLessEqual(bottom, size[1] - 2 * canvas.pad - canvas.small.size)
                if first == "I":
                    self.assertGreater(bottom - top, size[1] // 2)
                elif first == "Alexandria":
                    self.assertGreater(font(face.size + 1, True).getbbox(text)[2], canvas.width)
                else:
                    self.assertIn("\n", text)

    def test_large_greeting_changes_to_compact_header_with_loaded_agenda(self):
        screen = Screen(0)
        # January 12 UTC is still January 11 in Manchester.
        expiry = int(datetime(2027, 1, 12, 2, tzinfo=UTC).timestamp() * 1000)
        screen.show("agenda", 0, Identity(1, 2, "01", "Sam", "member", expiry))
        size = (720, 1280)
        with patch.object(ImageDraw.ImageDraw, "multiline_text", autospec=True) as initial:
            render(size, screen, self.now, {"events": []})
        screen.welcome_presented_at = 0
        with patch.object(Canvas, "text", autospec=True) as labels, \
                patch.object(ImageDraw.ImageDraw, "multiline_text", autospec=True) as dated:
            render(size, screen, self.now, {})
        self.assertEqual(initial.call_args.args[1:], dated.call_args.args[1:])
        self.assertEqual(initial.call_args.kwargs["font"].size, dated.call_args.kwargs["font"].size)
        self.assertIn("Member through January 11, 2027", [call.args[3] for call in labels.call_args_list])
        screen.greeting = False
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

    def assert_intact_qr(self, image, dimmed):
        # Only the QR modules are pure black on these pages of text and icons.
        # The three finder patterns touch the outer rows and columns of modules.
        ink_bounds = image.convert("L").point(lambda v: 0 if v else 255).getbbox()
        self.assertIsNotNone(ink_bounds, "No QR modules found in the frame")
        x, y, right, bottom = ink_bounds
        modules = qr_modules()
        scale, remainder = divmod(right - x, modules.width - 8)
        self.assertEqual((remainder, bottom - y), (0, right - x))
        self.assertGreaterEqual(scale, 3)
        quiet = 4 * scale
        box = (x - quiet, y - quiet, right + quiet, bottom + quiet)
        self.assertGreaterEqual(min(box[:2]), 0)
        self.assertLessEqual(box[2], image.width)
        self.assertLessEqual(box[3], image.height)
        crop = image.crop(box)
        white = crop.getpixel((0, 0))[0]
        self.assertGreaterEqual(white, 128)
        if dimmed:
            self.assertLess(white, 255)
        expected = modules.resize(crop.size, Image.Resampling.NEAREST).point(lambda v: white if v else 0)
        self.assertEqual(crop.tobytes(), expected.tobytes())
        return box

    def test_board_has_intact_qr_on_every_page(self):
        board = {"recent": [(f"First{i}", "8:15 PM") for i in range(5)],
                 "leaders": [(f"Member {i}.", "32 pts") for i in range(10)],
                 "opportunities": [(f"Weekly task {i}", "2 pts") for i in range(10)]}
        for size in [(320, 240), (480, 320), (320, 480), (1280, 720), (720, 1280), (1920, 1080)]:
            count = render(size, Screen(0), self.now, board)[1]
            if size in ((1280, 720), (1920, 1080)):
                self.assertEqual(count, 1)
            if size == (480, 320):
                self.assertGreater(count, 1)
            for dimmed in (False, True):
                corners = set()
                for variant in range(4):
                    positions = set()
                    for page in range(count):
                        with self.subTest(size=size, dimmed=dimmed, variant=variant, page=page):
                            image, pages = render(size, Screen(0), self.now, board, page,
                                                  variant=variant, dimmed=dimmed)
                            self.assertEqual(pages, count)
                            box = self.assert_intact_qr(image, dimmed)
                            positions.add(box)
                            corners.add((box[0] + box[2] < size[0], box[1] + box[3] < size[1]))
                    self.assertEqual(len(positions), 1)
                self.assertEqual(len(corners), 4)

    def test_spare_row_before_volunteers_preserves_page_contents_and_qr_position(self):
        size = (800, 480)
        canvas = Canvas(size)
        # Baseline capacity for a single check-in row and the two section headings.
        available = size[1] - canvas.header_height(True) - 2 * canvas.pad - canvas.small.size
        checkins_height = 2 * canvas.line + canvas.small.size
        capacity = (available - checkins_height) // canvas.line - 1
        names = [f"Leader{i}" for i in range(capacity + 1)]
        data = {"recent": [("Sam", "8 AM")], "leaders": [(name, "") for name in names]}
        boxes = []
        for page, expected_gap in enumerate((0, canvas.line)):
            with patch.object(canvas, "heading", wraps=canvas.heading) as headings, \
                    patch.object(canvas, "text", wraps=canvas.text) as text:
                self.assertEqual(canvas.board(Screen(0), self.now, "November 23", data, page), 2)
            checkins, leaders, work = [call.args[1] for call in headings.call_args_list]
            self.assertIn("Volunteer Opportunities", [call.args[2] for call in text.call_args_list])
            self.assertEqual(leaders - checkins - checkins_height, expected_gap)
            self.assertEqual(work, leaders)
            visible = [call.args[2] for call in text.call_args_list if call.args[2] in names]
            self.assertEqual(visible, names[page * capacity:(page + 1) * capacity])
            boxes.append(self.assert_intact_qr(canvas.image, dimmed=False))
        self.assertEqual(boxes[0], boxes[1])

    def test_roomy_board_grows_qr_after_reserving_a_blank_row(self):
        for size in ((1280, 720), (720, 1280)):
            for variant, dimmed in product(range(4), (False, True)):
                canvas = Canvas(size, variant=variant, dimmed=dimmed, stroke=1)
                data = {"recent": [("Sam", "8 AM")], "opportunities": [("Sweep", "1 pt")]}
                screen = Screen(0)
                date = "Sunday, November 22"
                with patch.object(canvas, "aligned_text", wraps=canvas.aligned_text) as labels:
                    _, base_qr = canvas.header(screen, self.now, date)
                baseline = [(c.args[3], c.args[4].size) for c in labels.call_args_list]
                with patch.object(canvas, "heading", wraps=canvas.heading) as headings, \
                        patch.object(canvas, "aligned_text", wraps=canvas.aligned_text) as labels:
                    self.assertEqual(canvas.board(screen, self.now, date, data, 0), 1)
                self.assertEqual([(c.args[3], c.args[4].size) for c in labels.call_args_list[:2]], baseline)
                checkins, leaders, work = [call.args[1] for call in headings.call_args_list]
                self.assertEqual(leaders - checkins, 3 * canvas.line + canvas.small.size)
                self.assertEqual(work, leaders)
                enlarged = self.assert_intact_qr(canvas.image, dimmed)
                self.assertGreater(enlarged[2] - enlarged[0], base_qr.side)

    def test_idle_qr_doubles_in_a_free_corner_and_clears_text_on_other_pages(self):
        # Leave room beside “Volunteer Opportunities” for the doubled QR with DejaVu Sans Bold.
        size = (1080, 480)
        canvas = Canvas(size, stroke=1)
        header = canvas.header_height(True)
        original = qr_image(header - canvas.pad).width
        body_height = canvas.h - header - 2 * canvas.pad - canvas.small.size
        checkins_height = 2 * canvas.line + canvas.small.size
        capacity = (body_height - checkins_height) // canvas.line - 1
        column_width = (canvas.width - canvas.pad) // 2
        long_label = "W" * int(column_width / canvas.body.getlength("W"))
        # Fill two pages. A single wide label on the second page limits both.
        for variant, wide_row in ((0, capacity), (3, 2 * capacity - 1)):
            palette = Canvas(size, variant=variant).palette
            band, paper = (ImageColor.getrgb(value) for value in (palette.band, palette.paper))
            for crowded in (False, True):
                rows = [(long_label if crowded and i == wide_row else "I", "") for i in range(2 * capacity)]
                data = {"recent": [("Sam", "8 AM")], "opportunities": rows}
                boxes = []
                for page in (0, 1):
                    with self.subTest(variant=variant, crowded=crowded, page=page):
                        args = (size, Screen(0), self.now, data, page)
                        image, pages = render(*args, variant=variant, stroke=1)
                        self.assertEqual(pages, 2)
                        box = self.assert_intact_qr(image, dimmed=False)
                        boxes.append(box)
                        side = box[2] - box[0]
                        if not crowded:
                            self.assertEqual(side, 2 * original)
                            boundary = header if variant == 0 else size[1] - header
                            self.assertLess(box[1], boundary)
                            self.assertGreater(box[3], boundary)
                            self.assertEqual(image.getpixel((0, boundary - 1)), band if variant == 0 else paper)
                            self.assertEqual(image.getpixel((0, boundary)), paper if variant == 0 else band)
                        elif variant == 0:
                            self.assertLess(original, side)
                            self.assertLess(side, 2 * original)
                        else:
                            self.assertEqual(side, original)
                        # Removing the QR must reveal only the two background colors.
                        with patch.object(BoardQR, "paint"):
                            background, _ = render(*args, variant=variant, stroke=1)
                        under_qr = background.crop(box).getcolors(side * side)
                        self.assertLessEqual({color for _, color in under_qr}, {band, paper})
                self.assertEqual(boxes[0], boxes[1])

    def test_each_palette_keeps_text_readable_and_dim_mode_reduces_peak_brightness(self):
        def luminance(color):
            rgb = [value / 255 for value in ImageColor.getrgb(color)]
            linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in rgb]
            return sum(weight * v for weight, v in zip((0.2126, 0.7152, 0.0722), linear))

        for variant in range(4):
            peaks = []
            for dimmed in (False, True):
                palette = Canvas((320, 240), variant=variant, dimmed=dimmed).palette
                for fg, bg in ((palette.ink, palette.paper), (palette.muted, palette.paper),
                               (palette.accent, palette.paper), (palette.title, palette.band),
                               (palette.kicker, palette.band)):
                    low, high = sorted((luminance(fg), luminance(bg)))
                    self.assertGreaterEqual((high + 0.05) / (low + 0.05), 4.5, (variant, dimmed, fg, bg))
                peaks.append(max(luminance(c) for c in (palette.paper, palette.ink, palette.title, palette.band)))
            self.assertLess(peaks[1], peaks[0])

    def test_required_rows_survive_on_a_short_display(self):
        names = [f"Person{i}" for i in range(5)]
        leaders = [(f"Leader{i}", "1 pt") for i in range(10)]
        jobs = [(f"Task{i}", "2 pts") for i in range(10)]
        board = {"recent": [(name, "8:15 PM") for name in names], "leaders": leaders, "opportunities": jobs}
        size = (320, 240)
        for variant in range(4):
            with self.subTest(variant=variant), patch.object(Canvas, "text", autospec=True) as printed:
                count = render(size, Screen(0), self.now, board, variant=variant)[1]
                for page in range(1, count):
                    render(size, Screen(0), self.now, board, page, variant=variant)
                lines = []
                for call in printed.call_args_list:
                    _, x, y, line, face, *_ = call.args
                    if call.kwargs.get("anchor", "lt").startswith("r"):
                        x -= face.getlength(line)
                    if call.kwargs.get("anchor", "lt").endswith("b"):
                        y -= face.size
                    self.assertGreaterEqual(min(x, y), 0)
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
        s.greeting = False
        data = {"reservations": [], "opportunities": [], "events": []}
        positions = set()
        for variant in range(4):
            image, pages = render((800, 480), s, self.now, data, variant=variant)
            self.assertEqual(pages, 1)
            box = self.assert_intact_qr(image, dimmed=False)
            positions.add(box[0] + box[2] < image.width)
        self.assertEqual(positions, {True, False})
        data["opportunities"] = [(f"Sort workshop materials {i}", "1 pt") for i in range(80)]
        with patch("welcomepi.render.qr_image", wraps=qr_image) as qr:
            for variant in range(4):
                _, count = render((480, 320), s, self.now, data, variant=variant)
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
        corners = set()
        for variant, thumbnail in product(range(4), (None, Image.new("RGB", (512, 512), "red"))):
            image, count = render((480, 320), s, self.now, {"details": Details(sections, 2), "avatar": thumbnail},
                                  variant=variant)
            self.assertEqual(image.size, (480, 320))
            self.assertGreater(count, 1)
            if thumbnail is not None:
                # The test avatar is the only fully saturated red on this page.
                x, y, right, bottom = image.getchannel("R").point(lambda v: 255 if v == 255 else 0).getbbox()
                self.assertEqual(right - x, bottom - y)
                corners.add((x + right < image.width, y + bottom < image.height))
        self.assertEqual(len(corners), 4)


class Hardware(unittest.TestCase):
    def test_personal_volunteer_point_minimum(self):
        env = {"MLAB_URI": "test", "LEDGER_URI": "test", "MQTT_HOST": "broker"}
        key = "WELCOMEPI_OPPORTUNITY_MIN_POINTS"
        self.assertEqual(Settings.load(env).opportunity_min_points, 1.0)
        self.assertEqual(Settings.load({**env, key: "0.75"}).opportunity_min_points, 0.75)
        for invalid in ("", "many", "-1", "NaN", "Infinity"):
            with self.assertRaisesRegex(ValueError, key):
                Settings.load({**env, key: invalid})

    def test_display_pixel_settings(self):
        env = {"MLAB_URI": "test", "LEDGER_URI": "test", "MQTT_HOST": "broker"}
        defaults = Settings.load(env)
        self.assertEqual((defaults.insets, defaults.font_stroke), ((0, 0, 0, 0), 0))
        env.update(WELCOMEPI_INSET="12", WELCOMEPI_INSET_RIGHT="32", WELCOMEPI_INSET_TOP="0",
                   WELCOMEPI_FONT_STROKE="1")
        settings = Settings.load(env)
        self.assertEqual((settings.insets, settings.font_stroke), ((12, 0, 32, 12), 1))
        for key, value in (("WELCOMEPI_INSET", "-1"), ("WELCOMEPI_INSET_BOTTOM", "1.5"),
                           ("WELCOMEPI_FONT_STROKE", "4")):
            with self.assertRaisesRegex(ValueError, key):
                Settings.load({**env, key: value})

    def test_board_appearance_intervals(self):
        env = {"MLAB_URI": "test", "LEDGER_URI": "test", "MQTT_HOST": "broker"}
        settings = Settings.load(env)
        self.assertEqual((settings.layout_interval_minutes, settings.dim_after_minutes), (7, 15))
        for key, field in (("WELCOMEPI_LAYOUT_INTERVAL_MINUTES", "layout_interval_minutes"),
                           ("WELCOMEPI_DIM_AFTER_MINUTES", "dim_after_minutes")):
            self.assertEqual(getattr(Settings.load({**env, key: "3"}), field), 3)
            for invalid in ("0", "-1", "1.5", "", "never"):
                with self.subTest(key=key, invalid=invalid), self.assertRaisesRegex(ValueError, key):
                    Settings.load({**env, key: invalid})

    def test_idle_display_modes(self):
        env = {"MLAB_URI": "test", "LEDGER_URI": "test", "MQTT_HOST": "broker"}
        self.assertEqual(Settings.load(env).idle_display, "black")
        for mode in ("black", "standby"):
            self.assertEqual(Settings.load({**env, "WELCOMEPI_IDLE_DISPLAY": mode}).idle_display, mode)
        for invalid in ("", "off"):
            with self.assertRaisesRegex(ValueError, "WELCOMEPI_IDLE_DISPLAY"):
                Settings.load({**env, "WELCOMEPI_IDLE_DISPLAY": invalid})

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
            selected.write_text("disconnected\n")  # HDMI0 remains connected throughout.
            self.assertFalse(display.probe(2, sleeping=True))
            self.assertIs(display.output, old)
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
            first.write_text("disconnected\n")
            self.assertFalse(display.probe(2, sleeping=True))
            self.output.assert_called_once_with(display.kms, "/dev/dri/card2", "HDMI-A-1", "auto")
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
        conn.has_prop.side_effect = lambda name: name == "link-status"
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
        requests[-1].add.assert_any_call(conn, "CRTC_ID", crtc.id)
        requests[-1].add.assert_any_call(crtc, {"MODE_ID": 7, "ACTIVE": 0})
        output.present(Image.new("RGB", (2, 3), "green"))
        requests[-1].add.assert_any_call(crtc, {"MODE_ID": 7, "ACTIVE": 1})
        requests[-1].add.assert_any_call(conn, "link-status", 0)
        requests[-1].add_plane.assert_called_once_with(plane, output.frames[1], crtc)
        requests[-1].commit_sync.assert_called_once_with(allow_modeset=True)
        self.assertNotEqual(output.maps[0][:], output.maps[1][:])
        output.disable()
        requests[-1].add.assert_any_call(crtc, {"MODE_ID": 0, "ACTIVE": 0})


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

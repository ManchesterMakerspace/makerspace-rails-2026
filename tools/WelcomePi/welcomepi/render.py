"""Resolution-aware Pillow layouts. Only the current page gets a pixel buffer."""
from dataclasses import dataclass
from datetime import datetime
from functools import lru_cache
from itertools import zip_longest
from math import ceil

from PIL import Image, ImageDraw, ImageFont, ImageOps
import qrcode

from .state import EASTERN, HOME


VARIANT_COUNT = 4


@dataclass(frozen=True)
class Palette:
    paper: str
    ink: str
    muted: str
    accent: str
    band: str
    title: str
    kicker: str
    line: str


LIGHT = Palette("#E8E4D7", "#192E30", "#435852", "#196154", "#24393D", "#EEF3E9", "#BADBD1", "#9DADA3")
DARK = Palette("#18252C", "#E0E9E7", "#ABBEBF", "#91C9CB", "#253B47", "#F0E4CC", "#CBD5D9", "#526972")
DIM_LIGHT = Palette("#91968B", "#101E1C", "#192B24", "#153027", "#14211E", "#A0A99B", "#93A698", "#637367")
DIM_DARK = Palette("#0A1015", "#9BA9AB", "#829296", "#82A1A2", "#111D25", "#A9A69A", "#94A2A4", "#3A4B53")


@lru_cache(maxsize=48)
def font(size, bold=False):
    weight = "Bold" if bold else "Regular"
    for filename in (f"/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-{weight}.ttf",
                     f"Roboto-{weight}.ttf", "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf",
                     "arialbd.ttf" if bold else "arial.ttf"):
        try:
            return ImageFont.truetype(filename, size)
        except OSError:
            continue
    raise OSError("Install fonts-dejavu-core or fonts-roboto")


def wrap(text, face, width, *, break_words=True):
    words = str(text).split()
    lines, line = [], ""
    for word in words:
        combined = (line + " " + word).strip()
        if face.getlength(combined) <= width:
            line = combined
            continue
        if line:
            lines.append(line)
        if not break_words or face.getlength(word) <= width:
            line = word
            continue
        line = ""
        # Long URLs and other unbroken text still have to fit the frame.
        for char in word:
            if line and face.getlength(line + char) > width:
                lines.append(line)
                line = ""
            line += char
    return lines + [line] if line else lines


def fit(text, face, width):
    if face.getlength(text) <= width:
        return text
    lo, hi = 0, len(text)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if face.getlength(text[:mid] + "…") <= width:
            lo = mid
        else:
            hi = mid - 1
    return text[:lo].rstrip() + "…"


@lru_cache(maxsize=2)
def qr_modules(dimmed=False):
    code = qrcode.QRCode(box_size=1, border=4, error_correction=qrcode.constants.ERROR_CORRECT_M)
    code.add_data(HOME)
    return code.make_image(fill_color="black", back_color="#AAAAAA" if dimmed else "white").convert("RGB")


def qr_image(space, dimmed=False):
    base = qr_modules(dimmed)
    scale = space // base.width
    if scale < 3:
        return None
    return base.resize((base.width * scale, base.height * scale), Image.Resampling.NEAREST)


def paired(row):
    label, detail = row
    return f"{label}  ·  {detail}" if detail else label


def agenda_complete(data):
    return all(key in data for key in ("reservations", "opportunities", "events"))


def agenda_ready(data):
    return bool(data.get("reservations") or data.get("opportunities") or agenda_complete(data))


def display_name(first):
    # MongoDB can hold legacy, unbounded values. Keep font measurements on a
    # small Pi bounded even if the first-name field contains a pasted document.
    text = str(first or "").strip()
    if len(text) > 256:
        text = text[:255].rstrip() + "…"
    return " ".join(text.split()) or "member"


def section_pages(sections, face, width, capacity):
    """Keep headings with at least one line and repeat them after a page break."""
    pages = [[]]
    for title, rows in sections:
        if not rows:
            continue
        if capacity - len(pages[-1]) < 2:
            pages.append([])
        pages[-1].append(("heading", title))
        for row in rows:
            for line in wrap(paired(row), face, width):
                if len(pages[-1]) == capacity:
                    pages.append([("heading", title)])
                pages[-1].append(("text", line))
    return pages


class Canvas:
    def __init__(self, size, *, variant=0, dimmed=False, stroke=0):
        self.w, self.h = size
        self.stroke = stroke
        # Top-right, bottom-left, top-left, bottom-right for the QR or avatar.
        self.lower_header = variant % 2 == 1
        self.media_left = variant % VARIANT_COUNT in (1, 2)
        self.dimmed = dimmed
        palettes = (DIM_LIGHT, DIM_DARK) if dimmed else (LIGHT, DARK)
        self.palette = palettes[variant % 2]
        self.image = Image.new("RGB", size, self.palette.paper)
        self.draw = ImageDraw.Draw(self.image)
        size = max(14, min(44, self.w // 36, self.h // 32))
        self.body = font(size)
        self.bold = font(size, True)
        self.small = font(max(12, size * 4 // 5))
        self.title = font(size * 2, True)
        self.pad = max(10, size)
        self.line = round(size * 1.55)
        self.width = self.w - 2 * self.pad

    def text(self, x, y, text, face, color=None, *, anchor="lt"):
        self.draw.text((x, y), text, font=face, fill=color or self.palette.ink, anchor=anchor, stroke_width=self.stroke)

    def aligned_text(self, x, y, width, text, face, color=None):
        if self.media_left:
            x += width - face.getlength(text)
        self.text(x, y, text, face, color)

    def greeting(self, first, date, expires_ms=None):
        status = fit(f"Active member  ·  {date}", self.small, self.width)
        status_x = self.w - self.pad if self.media_left else self.pad
        status_y = self.pad if self.lower_header else self.h - self.pad
        anchor = ("r" if self.media_left else "l") + ("t" if self.lower_header else "b")
        self.text(status_x, status_y, status, self.small, self.palette.muted, anchor=anchor)
        # Reserve the date line from the first frame so adding it never moves the name.
        room = self.h - 3 * self.pad - self.small.size - self.line
        start_y = 2 * self.pad + self.small.size if self.lower_header else self.pad
        gap = self.pad // 2
        greeting_name = f"{display_name(first)}!"
        # Prefer whole words, except when doing so would shrink a long name
        # below even the regular agenda text size.
        break_words = any(self.bold.getlength(word) > self.width for word in greeting_name.split())

        def layout(size, truncate=False):
            # Reuse the resolved typeface. Searching installed fonts at each
            # trial size would slow the first frame on a Pi Zero.
            face = self.bold.font_variant(size=size)
            name = (fit(greeting_name, face, self.width) if truncate else
                    "\n".join(wrap(greeting_name, face, self.width, break_words=break_words)))
            box = self.draw.multiline_textbbox((0, 0), name, font=face, spacing=gap, align="center",
                                               stroke_width=self.stroke)
            welcome = self.bold.font_variant(size=max(1, min(size // 2, self.w // 8, self.h // 7)))
            left, welcome_top, right, welcome_bottom = welcome.getbbox("Welcome,", anchor="mt", stroke_width=self.stroke)
            width = max(box[2] - box[0], 2 * max(-left, right))
            height = welcome_bottom - welcome_top + gap + box[3] - box[1]
            return face, name, box, welcome, width, height

        # Keep words intact as the name grows. Fit both the ink (including
        # accents and descenders) and the space above it for the salutation.
        low, high = 1, max(1, 2 * room)
        while low < high:
            trial = (low + high + 1) // 2
            *_, width, height = layout(trial)
            if width <= self.width and height <= room:
                low = trial
            else:
                high = trial - 1
        face, name, box, welcome, width, height = layout(low)
        if width > self.width or height > room:
            face, name, box, welcome, width, height = layout(low, truncate=True)
        # Move only within the spare room left by the largest fitting name.
        top = start_y + (room - height) * (3 if self.lower_header else 1) // 4
        center = self.pad + (self.width - width) * (1 if self.media_left else 3) // 4 + width // 2
        self.text(center, top + self.stroke, "Welcome,", welcome, self.palette.accent, anchor="mt")
        x = center - (box[2] - box[0]) // 2 - box[0]
        y = top + height - box[3]
        self.draw.multiline_text((x, y), name, font=face, fill=self.palette.ink, spacing=gap, align="center",
                                 stroke_width=self.stroke)
        if expires_ms is not None:
            try:
                expires = datetime.fromtimestamp(expires_ms / 1000, EASTERN)
            except (OSError, ValueError, OverflowError):
                return  # A legacy out-of-range timestamp cannot supply a calendar date.
            label = f"Member through {expires:%B} {expires.day}, {expires.year}"
            face = self.body
            while face.size > 1 and face.getlength(label) + 2 * self.stroke > self.width:
                face = font(face.size - 1)
            self.text(self.w // 2, top + height + gap, label, face, self.palette.ink, anchor="mt")

    def heading(self, x, y, title, width):
        side = self.bold.size
        stroke = max(1, side // 9)
        accent = self.palette.accent
        icon = Image.new("RGB", (side, side), self.palette.paper)
        pen = ImageDraw.Draw(icon)
        if title in ("Your reservations", "Today on Eventbrite"):
            pen.rounded_rectangle((1, side//5, side-2, side-2), 2, outline=accent, width=stroke)
            pen.line((2, side//2, side-3, side//2), fill=accent, width=stroke)
            for a in (side//3, 2*side//3):
                pen.line((a, 0, a, side//3), fill=accent, width=stroke)
        elif title in ("Recent check-ins", "Character sheet"):
            pen.ellipse((side//3, 1, 2*side//3, side//2), outline=accent, width=stroke)
            pen.arc((1, side//2, side-2, side+side//3), 180, 360, fill=accent, width=stroke)
        elif title in ("Volunteer leaders", "Progress"):
            for i in range(3):
                pen.rectangle((i*side//3, (2-i)*side//4 + 2, (i+1)*side//3-2, side-2), fill=accent)
        elif title == "Kudos received":
            pen.regular_polygon(((side/2, side/2), side*0.46), 5, outline=accent)
        else:
            pen.ellipse((1, 1, side-2, side-2), outline=accent, width=stroke)
            pen.line([(side//4, side//2), (side*4//9, side*2//3), (side*3//4, side//3)], fill=accent, width=stroke)
        self.image.paste(icon, (x, y))
        inset = side + side//2
        self.text(x + inset, y, fit(title, self.bold, width - inset), self.bold, accent)

    def header_height(self, board):
        height = min(self.title.size + self.small.size + 3 * self.pad, max(80, self.h // 3))
        return max(height, qr_modules(self.dimmed).width * 3 + self.pad) if board else height

    def header(self, screen, today, date, details=None, avatar=None, *, spare=0):
        board = screen.page == "board"
        height = self.header_height(board)
        available = self.width
        if board:
            modules = qr_modules(self.dimmed).width
            qr_side = (height - self.pad) // modules * modules
            available -= qr_side + self.pad
            kicker, headline = "Manchester Makerspace", date
            if self.bold.getlength(headline) > available:
                headline = f"{today:%a, %b} {today.day}"
        else:
            kicker = f"Active member  ·  {date}"
            first = display_name(screen.member.first)
            headline = f"Welcome, {first}!" if screen.page == "agenda" else first
            if details and details.rank is not None:
                side = height - self.pad
                available -= side + self.pad
            if self.small.getlength(kicker) > available:
                kicker = f"Active member  ·  {today:%b} {today.day}"

        # Preserve the original labels and font sizes when enlarging the QR.
        face = self.title
        while face.size > self.bold.size and face.getlength(headline) > available:
            face = font(face.size - 2, True)
        kicker = fit(kicker, self.small, available)
        headline = fit(headline, face, available)
        if board:
            text_width = ceil(max(self.small.getlength(kicker), face.getlength(headline))) + 2 * self.stroke
            qr_room = min(self.width - self.pad - text_width, height + spare - self.pad)
            qr_side = max(qr_side, qr_room // modules * modules)
            height = max(height, qr_side + self.pad)
            available = self.width - qr_side - self.pad
        top = self.h - height if self.lower_header else 0
        self.draw.rectangle((0, top, self.w, top + height - 1), fill=self.palette.band)
        if board:
            qr = qr_image(qr_side, self.dimmed)
            x = self.pad if self.media_left else self.w - self.pad - qr_side
            self.image.paste(qr, (x, top + (height - qr_side) // 2))
        elif details and details.rank is not None:
            x = self.pad if self.media_left else self.w - self.pad - side
            y = top + (height - side) // 2
            if avatar:
                self.image.paste(avatar.resize((side, side), Image.Resampling.LANCZOS), (x, y))
            else:
                self.draw.regular_polygon(((x + side / 2, y + side / 2), side * 0.45), 6, fill=self.palette.kicker)
                self.text(x + side / 2, y + side / 2, str(details.rank), self.title, self.palette.band, anchor="mm")
        x = self.w - self.pad - available if self.media_left else self.pad
        self.aligned_text(x, top + self.pad, available, kicker, self.small, self.palette.kicker)
        self.aligned_text(x, top + self.pad + self.small.size + self.pad // 2, available,
                          headline, face, self.palette.title)
        return (self.pad, top - self.pad) if self.lower_header else (height + self.pad, self.h - self.pad)

    def reserve_footer(self, bounds, height, gap=0):
        """Return the body limits and the cue origin opposite the header."""
        top, bottom = bounds
        if self.lower_header:
            return top + height + gap, bottom, top
        return top, bottom - height - gap, bottom - height

    def board(self, screen, today, date, data, page):
        body_height = self.h - self.header_height(True) - 2 * self.pad - self.small.size
        arrivals = data.get("recent", [])
        columns = max(1, min(5, self.width // (self.small.size * 8)))
        cell_width = self.width // columns
        arrival_height = self.line + self.small.size
        arrival_rows = (len(arrivals) + columns - 1) // columns
        checkin_height = self.line + arrival_rows * arrival_height
        width = (self.width - self.pad) // 2
        rows = []
        for left, right in zip_longest(data.get("leaders", []), data.get("opportunities", [])):
            left_lines = wrap(paired(left), self.body, width) if left else []
            right_lines = wrap(paired(right), self.body, width) if right else []
            rows.extend(zip_longest(left_lines, right_lines, fillvalue=""))

        # Keep useful groups of rankings together. Very short displays can
        # page the arrivals themselves before showing the paired lists.
        separate = checkin_height > body_height or (rows and body_height - checkin_height < 4 * self.line)
        arrival_capacity = max(1, (body_height - self.line) // arrival_height)
        per_arrival_page = arrival_capacity * columns
        arrival_pages = max(1, (len(arrivals) + per_arrival_page - 1) // per_arrival_page) if separate else 0
        list_space = body_height if separate else body_height - checkin_height
        capacity = max(1, list_space // self.line - 1)
        count = max(1, arrival_pages + (len(rows) + capacity - 1) // capacity)
        p = page % count
        # Keep page boundaries fixed. Only the space left on the fullest page
        # can enlarge a header shared across the page cycle.
        volunteer_height = (1 + min(capacity, len(rows))) * self.line
        if separate:
            used = max(self.line + min(arrival_rows, arrival_capacity) * arrival_height,
                       volunteer_height if rows else 0)
        else:
            used = checkin_height + volunteer_height
            if arrivals and rows and body_height - used >= self.line:
                used += self.line
        bounds = self.header(screen, today, date, spare=max(0, body_height - used))
        top, bottom, _ = self.reserve_footer(bounds, self.small.size)
        if not separate or p < arrival_pages:
            self.heading(self.pad, top, "Recent check-ins", self.width)
            start = p * per_arrival_page if separate else 0
            for i, (first, clock) in enumerate(arrivals[start:start + per_arrival_page]):
                x = self.pad + i % columns * cell_width
                cy = top + self.line + i // columns * arrival_height
                name = fit(first, self.bold, cell_width - 5)
                self.aligned_text(x, cy, cell_width - 5, name, self.bold)
                self.aligned_text(x, cy + self.bold.size + 2, cell_width - 5, clock, self.small, self.palette.muted)
            if separate:
                return count
        offset = (p - arrival_pages) * capacity
        page_rows = rows[offset:offset + capacity]
        list_top = top if separate else top + checkin_height
        if not separate and arrivals and page_rows and bottom - list_top >= (len(page_rows) + 2) * self.line:
            list_top += self.line
        y = list_top
        right_x = self.pad + width + self.pad
        leader_x, work_x = (right_x, self.pad) if self.media_left else (self.pad, right_x)
        self.heading(leader_x, y, "Volunteer leaders", width)
        self.heading(work_x, y, "Open volunteering", width)
        y += self.line
        for left, right in page_rows:
            self.text(leader_x, y, left, self.body)
            self.text(work_x, y, right, self.body)
            y += self.line
        self.draw.line((right_x - self.pad // 2, list_top, right_x - self.pad // 2, y), fill=self.palette.line)
        return count

    def personal(self, page_name, data, bounds, page):
        cue = ("Tap again to show your character or your private kudos and checkouts here."
               if page_name == "agenda" else "Tap again to clear this screen.")
        cue_lines = wrap(cue, self.small, self.width - 4 * self.small.size)
        top, bottom, cue_y = self.reserve_footer(bounds, len(cue_lines) * (self.small.size + 3), self.pad // 2)
        capacity = max(2, (bottom - top) // self.line)
        if page_name == "agenda":
            sections = [("Your reservations", data.get("reservations", [])),
                        ("Volunteer opportunities", data.get("opportunities", []))]
        else:
            details = data.get("details")
            sections = details.sections if details else []
            if details and not any(rows for _, rows in sections):
                sections = [("Member details", [("No received kudos or current checkouts.", "")])]
        inset = self.pad // 2
        x = self.pad + (inset if self.media_left else 0)
        width = self.width - inset
        pages = section_pages(sections, self.body, width, capacity)
        p = page % len(pages)
        y = top
        for kind, line in pages[p]:
            if kind == "heading":
                self.heading(x, y, line, width)
            else:
                self.text(x, y, line, self.body)
            y += self.line
        if page_name == "agenda" and p == len(pages) - 1 and agenda_complete(data):
            events = data["events"]
            if events and bottom - y >= 2 * self.line:
                self.heading(x, y, "Today on Eventbrite", width)
                y += self.line
                for event in events:
                    if y + self.line > bottom:
                        break
                    self.text(x, y, fit(paired(event), self.body, width), self.body)
                    y += self.line
            qr = qr_image(min(bottom - y, width, self.line * 5), self.dimmed)
            if qr:
                qr_x = self.w - self.pad - qr.width if self.media_left else self.pad
                self.image.paste(qr, (qr_x, bottom - qr.height if self.lower_header else y))
        for line in cue_lines:
            self.aligned_text(self.pad, cue_y, self.width, line, self.small, self.palette.muted)
            cue_y += self.small.size + 3
        return len(pages)


def render(size, screen, now, data, page=0, *, variant=0, dimmed=False, insets=(0, 0, 0, 0), stroke=0):
    left, top, right, bottom = insets
    viewport = (size[0] - left - right, size[1] - top - bottom)
    if min(viewport) <= 0:
        raise ValueError(f"WelcomePi insets {insets} leave no visible area on a {size[0]}x{size[1]} display")
    canvas = Canvas(viewport, variant=variant, dimmed=dimmed, stroke=stroke)
    count = draw_page(canvas, screen, now, data, page)
    image = ImageOps.expand(canvas.image, border=insets, fill="black") if any(insets) else canvas.image
    return image, count


def draw_page(canvas, screen, now, data, page):
    today = now.astimezone(EASTERN)
    date = f"{today:%A, %B} {today.day}"
    if screen.page == "welcome":
        canvas.greeting(screen.record_first, date)
        return 1
    if screen.greeting:
        expires_ms = screen.member.expires_ms if screen.welcome_presented_at is not None else None
        canvas.greeting(screen.member.first, date, expires_ms)
        return 1
    if screen.page == "board":
        count = canvas.board(screen, today, date, data, page)
    else:
        bounds = canvas.header(screen, today, date, data.get("details"), data.get("avatar"))
        count = canvas.personal(screen.page, data, bounds, page)
    if count > 1:
        x = canvas.pad if canvas.media_left else canvas.w - canvas.pad
        y = canvas.pad if canvas.lower_header else canvas.h - canvas.pad
        anchor = ("l" if canvas.media_left else "r") + ("t" if canvas.lower_header else "b")
        canvas.text(x, y, f"{page % count + 1}/{count}", canvas.small, canvas.palette.muted, anchor=anchor)
    return count

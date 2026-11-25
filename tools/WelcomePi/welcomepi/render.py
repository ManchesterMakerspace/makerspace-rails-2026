"""Resolution-aware Pillow layouts. Only the current page gets a pixel buffer."""
from functools import lru_cache
from itertools import zip_longest

from PIL import Image, ImageDraw, ImageFont
import qrcode

from .state import EASTERN, HOME


PAPER = "#F5F3EA"
INK = "#162F31"
MUTED = "#455F60"
ACCENT = "#13675C"
LIGHT = "#B8E2CF"
LINE = "#B8C8BE"


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


@lru_cache(maxsize=1)
def qr_modules():
    code = qrcode.QRCode(box_size=1, border=4, error_correction=qrcode.constants.ERROR_CORRECT_M)
    code.add_data(HOME)
    return code.make_image().convert("RGB")


def qr_image(space):
    base = qr_modules()
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
    def __init__(self, size):
        self.w, self.h = size
        self.image = Image.new("RGB", size, PAPER)
        self.draw = ImageDraw.Draw(self.image)
        size = max(14, min(44, self.w // 36, self.h // 32))
        self.body = font(size)
        self.bold = font(size, True)
        self.small = font(max(12, size * 4 // 5))
        self.title = font(size * 2, True)
        self.pad = max(10, size)
        self.line = round(size * 1.55)
        self.width = self.w - 2 * self.pad

    def text(self, x, y, text, face, color=INK):
        self.draw.text((x, y), text, font=face, fill=color, anchor="lt")

    def greeting(self, first, date):
        self.draw.rectangle((0, 0, self.w, self.h), fill=INK)
        status = fit(f"Active member  ·  {date}", self.small, self.width)
        self.draw.text((self.w // 2, self.h - self.pad), status, font=self.small, fill=LIGHT, anchor="mb")
        bottom = self.h - 2 * self.pad - self.small.size
        gap = self.pad // 2
        greeting_name = f"{display_name(first)}!"
        # Prefer whole words, except when doing so would shrink a long name
        # below even the regular agenda text size.
        break_words = any(self.bold.getlength(word) > self.width for word in greeting_name.split())

        def layout(size):
            # Reuse the resolved typeface. Searching installed fonts at each
            # trial size would slow the first frame on a Pi Zero.
            face = self.bold.font_variant(size=size)
            name = "\n".join(wrap(greeting_name, face, self.width, break_words=break_words))
            box = self.draw.multiline_textbbox((0, 0), name, font=face, spacing=gap, align="center")
            welcome = self.bold.font_variant(size=max(1, min(size // 2, self.w // 8, self.h // 7)))
            welcome_height = welcome.getbbox("Welcome,", anchor="lt")[3]
            height = welcome_height + gap + box[3] - box[1]
            return face, name, box, welcome, height

        # Keep words intact as the name grows. Fit both the ink (including
        # accents and descenders) and the space above it for the salutation.
        low, high = 1, max(1, 2 * bottom)
        while low < high:
            trial = (low + high + 1) // 2
            _, _, box, _, height = layout(trial)
            if box[2] - box[0] <= self.width and height <= bottom - self.pad:
                low = trial
            else:
                high = trial - 1
        face, name, box, welcome, height = layout(low)
        if box[2] - box[0] > self.width or height > bottom - self.pad:
            name = fit(greeting_name, face, self.width)
            box = face.getbbox(name)
            height = welcome.getbbox("Welcome,", anchor="lt")[3] + gap + box[3] - box[1]
        top = self.pad + (bottom - self.pad - height) // 2
        self.draw.text((self.w // 2, top), "Welcome,", font=welcome, fill=LIGHT, anchor="mt")
        x = (self.w - (box[2] - box[0])) // 2 - box[0]
        y = top + height - box[3]
        self.draw.multiline_text((x, y), name, font=face, fill="white", spacing=gap, align="center")

    def heading(self, x, y, title, width):
        side = self.bold.size
        stroke = max(1, side // 9)
        icon = Image.new("RGB", (side, side), PAPER)
        pen = ImageDraw.Draw(icon)
        if title in ("Your reservations", "Today on Eventbrite"):
            pen.rounded_rectangle((1, side//5, side-2, side-2), 2, outline=ACCENT, width=stroke)
            pen.line((2, side//2, side-3, side//2), fill=ACCENT, width=stroke)
            for a in (side//3, 2*side//3):
                pen.line((a, 0, a, side//3), fill=ACCENT, width=stroke)
        elif title in ("Recent check-ins", "Character sheet"):
            pen.ellipse((side//3, 1, 2*side//3, side//2), outline=ACCENT, width=stroke)
            pen.arc((1, side//2, side-2, side+side//3), 180, 360, fill=ACCENT, width=stroke)
        elif title in ("Volunteer leaders", "Progress"):
            for i in range(3):
                pen.rectangle((i*side//3, (2-i)*side//4 + 2, (i+1)*side//3-2, side-2), fill=ACCENT)
        elif title == "Kudos received":
            pen.regular_polygon(((side/2, side/2), side*0.46), 5, outline=ACCENT)
        else:
            pen.ellipse((1, 1, side-2, side-2), outline=ACCENT, width=stroke)
            pen.line([(side//4, side//2), (side*4//9, side*2//3), (side*3//4, side//3)], fill=ACCENT, width=stroke)
        self.image.paste(icon, (x, y))
        inset = side + side//2
        self.text(x + inset, y, fit(title, self.bold, width - inset), self.bold, ACCENT)

    def header(self, screen, today, date, details=None, avatar=None):
        board = screen.page == "board"
        height = min(self.title.size + self.small.size + 3 * self.pad, max(80, self.h // 3))
        if board:
            height = max(height, qr_modules().width * 3 + self.pad)
        self.draw.rectangle((0, 0, self.w, height - 1), fill=INK)
        available = self.width
        if board:
            qr = qr_image(height - self.pad)
            if qr:
                self.image.paste(qr, (self.w - self.pad - qr.width, (height - qr.height) // 2))
                available -= qr.width + self.pad
            kicker, headline = "Manchester Makerspace", date
            if self.bold.getlength(headline) > available:
                headline = f"{today:%a, %b} {today.day}"
        else:
            kicker = f"Active member  ·  {date}"
            first = display_name(screen.member.first)
            headline = f"Welcome, {first}!" if screen.page == "agenda" else first
            if details and details.rank is not None:
                side = height - self.pad
                x, y = self.w - self.pad - side, (height - side) // 2
                if avatar:
                    self.image.paste(avatar.resize((side, side), Image.Resampling.LANCZOS), (x, y))
                else:
                    self.draw.regular_polygon(((x + side / 2, y + side / 2), side * 0.45), 6, fill=LIGHT)
                    self.draw.text((x + side / 2, y + side / 2), str(details.rank), fill=INK,
                                   font=self.title, anchor="mm")
                available -= side + self.pad
            if self.small.getlength(kicker) > available:
                kicker = f"Active member  ·  {today:%b} {today.day}"
        self.text(self.pad, self.pad, fit(kicker, self.small, available), self.small, LIGHT)
        face = self.title
        while face.size > self.bold.size and face.getlength(headline) > available:
            face = font(face.size - 2, True)
        self.text(self.pad, self.pad + self.small.size + self.pad // 2,
                  fit(headline, face, available), face, "white")
        return height + self.pad

    def board(self, data, top, page):
        arrivals = data.get("recent", [])
        columns = max(1, min(5, self.width // (self.small.size * 8)))
        cell_width = self.width // columns
        arrival_height = self.line + self.small.size
        arrival_rows = (len(arrivals) + columns - 1) // columns
        below_arrivals = top + self.line + arrival_rows * arrival_height
        width = (self.width - self.pad) // 2
        rows = []
        for left, right in zip_longest(data.get("leaders", []), data.get("opportunities", [])):
            left_lines = wrap(paired(left), self.body, width) if left else []
            right_lines = wrap(paired(right), self.body, width) if right else []
            rows.extend(zip_longest(left_lines, right_lines, fillvalue=""))

        bottom = self.h - self.pad - self.small.size
        # Keep useful groups of rankings together. Very short displays can
        # page the arrivals themselves before showing the paired lists.
        separate = below_arrivals > bottom or (rows and bottom - below_arrivals < 4 * self.line)
        per_arrival_page = max(1, (bottom - top - self.line) // arrival_height) * columns
        arrival_pages = max(1, (len(arrivals) + per_arrival_page - 1) // per_arrival_page) if separate else 0
        list_top = top if separate else below_arrivals
        capacity = max(1, (bottom - list_top) // self.line - 1)
        count = max(1, arrival_pages + (len(rows) + capacity - 1) // capacity)
        p = page % count
        if not separate or p < arrival_pages:
            self.heading(self.pad, top, "Recent check-ins", self.width)
            start = p * per_arrival_page if separate else 0
            for i, (first, clock) in enumerate(arrivals[start:start + per_arrival_page]):
                x = self.pad + i % columns * cell_width
                cy = top + self.line + i // columns * arrival_height
                self.text(x, cy, fit(first, self.bold, cell_width - 5), self.bold)
                self.text(x, cy + self.bold.size + 2, clock, self.small, MUTED)
            if separate:
                return count
        y = list_top
        self.heading(self.pad, y, "Volunteer leaders", width)
        right_x = self.pad + width + self.pad
        self.heading(right_x, y, "Open volunteering", width)
        y += self.line
        offset = (p - arrival_pages) * capacity
        for left, right in rows[offset:offset + capacity]:
            self.text(self.pad, y, left, self.body)
            self.text(right_x, y, right, self.body)
            y += self.line
        self.draw.line((right_x - self.pad // 2, list_top, right_x - self.pad // 2, y), fill=LINE)
        return count

    def personal(self, page_name, data, top, page):
        cue = ("Tap again to show your character or your private kudos and checkouts here."
               if page_name == "agenda" else "Tap again to clear this screen.")
        cue_lines = wrap(cue, self.small, self.width - 4 * self.small.size)
        bottom = self.h - self.pad - len(cue_lines) * (self.small.size + 3) - self.pad // 2
        capacity = max(2, (bottom - top) // self.line)
        if page_name == "agenda":
            sections = [("Your reservations", data.get("reservations", [])),
                        ("Volunteer opportunities", data.get("opportunities", []))]
        else:
            details = data.get("details")
            sections = details.sections if details else []
            if details and not any(rows for _, rows in sections):
                sections = [("Member details", [("No received kudos or current checkouts.", "")])]
        pages = section_pages(sections, self.body, self.width, capacity)
        p = page % len(pages)
        y = top
        for kind, line in pages[p]:
            if kind == "heading":
                self.heading(self.pad, y, line, self.width)
            else:
                self.text(self.pad, y, line, self.body)
            y += self.line
        if page_name == "agenda" and p == len(pages) - 1 and agenda_complete(data):
            events = data["events"]
            if events and bottom - y >= 2 * self.line:
                self.heading(self.pad, y, "Today on Eventbrite", self.width)
                y += self.line
                for event in events:
                    if y + self.line > bottom:
                        break
                    self.text(self.pad, y, fit(paired(event), self.body, self.width), self.body)
                    y += self.line
            qr = qr_image(min(bottom - y, self.width, self.line * 5))
            if qr:
                self.image.paste(qr, (self.pad, y))
        y = bottom + self.pad // 2
        for line in cue_lines:
            self.text(self.pad, y, line, self.small, MUTED)
            y += self.small.size + 3
        return len(pages)


def render(size, screen, now, data, page=0):
    canvas = Canvas(size)
    today = now.astimezone(EASTERN)
    date = f"{today:%A, %B} {today.day}"
    if screen.page == "welcome":
        canvas.greeting(screen.record_first, date)
        return canvas.image, 1
    if screen.greeting and not agenda_ready(data):
        canvas.greeting(screen.member.first, date)
        return canvas.image, 1
    top = canvas.header(screen, today, date, data.get("details"), data.get("avatar"))
    count = (canvas.board(data, top, page) if screen.page == "board"
             else canvas.personal(screen.page, data, top, page))
    if count > 1:
        canvas.draw.text((canvas.w - canvas.pad, canvas.h - canvas.pad), f"{page % count + 1}/{count}",
                         font=canvas.small, fill=MUTED, anchor="rb")
    return canvas.image, count

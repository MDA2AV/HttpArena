"""The social cards: the image a shared link unfurls into, one per page.

Drawn with Pillow in the look of the site's dark theme (site/root/assets/sr/sr.css):
the header with its hazard tape, the screwed-down plate with the page's title, and a
rack with one unit per protocol family, lit where the page is about that family.

A card says what a link is about and holds no results. The services that show it keep
it for weeks, so a rank or a score on it would soon disagree with the page behind it.

gen_leaderboard_data.py calls draw() for every page it writes. Everything that does
not differ between cards is drawn once, at twice the size, and scaled down: Pillow
does not antialias shapes. The text goes on top at its own size.
"""

from __future__ import annotations

import functools
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:                      # the pages then come out without og:image
    Image = None

# Part of every card's address. Raise it when the design changes: the services that
# unfurl links cache an image by its address.
VERSION = 2

W, H = 1200, 630
S = 2                                    # the scale the hardware is drawn at

FONTS = Path(__file__).resolve().parent.parent / "site" / "root" / "assets" / "sr" / "fonts"
SYSTEM_FONTS = "/usr/share/fonts/truetype/"

BG, HEADER, LINE, PANEL = "#090b0e", "#0e1114", "#383f47", "#1a1e23"
TEXT, TEXT_2, MUTED, OFF = "#f2f4f6", "#c6cdd5", "#9da7b2", "#66707b"
ACCENT, GREEN, AMBER, LED_OFF = "#62c4ff", "#3dff8f", "#ffb020", "#2c3238"
HAZARD, HAZARD_DARK = "#f2bd00", "#20242a"
EDGE_HI, EDGE_LO, PLATE, PLATE_LINE = "#3b424a", "#08090b", "#111417", "#353c44"
TYPE_COLOR = {"flagship": "#5cc596", "emerging": "#9bbdec", "experimental": "#e8b066",
              "engine": "#e89384", "infrastructure": "#6cc3d2"}

HEAD_H, TAPE_H = 92, 10
CARD = (48, 142, 772, 566)               # the plate with the text
RACK = (808, 142, 1152, 566)
PAD = 46
UNIT_H, UNIT_GAP, POST = 52, 5, 24


def ready():
    return Image is not None and hasattr(Image, "Quantize")      # Pillow 9.1


# ── text ─────────────────────────────────────────────────────────────────────

@functools.lru_cache(maxsize=None)
def _font(kind, size):
    """The site's own fonts, so a card looks the same wherever it is drawn."""
    name, weight = {"title": ("saira-sc-700.woff2", None), "label": ("saira-sc-600.woff2", None),
                    "body": ("inter.woff2", 420), "mono": ("redhat-mono.woff2", 500)}[kind]
    try:
        font = ImageFont.truetype(str(FONTS / name), size)
        if weight:
            font.set_variation_by_axes([weight])
        return font
    except (OSError, NotImplementedError):      # a FreeType built without WOFF2
        _warn_fonts()
    bold = kind in ("title", "label")
    for path in ("dejavu/DejaVuSans%s.ttf" % ("-Bold" if bold else ""),
                 "liberation/LiberationSans-%s.ttf" % ("Bold" if bold else "Regular")):
        try:
            return ImageFont.truetype(SYSTEM_FONTS + path, round(size * .86))
        except OSError:
            continue
    return ImageFont.load_default(size=size)


@functools.lru_cache(maxsize=None)
def _warn_fonts():
    print("[warn] og cards: this Pillow cannot read the site's WOFF2 fonts - using a system font")


@functools.lru_cache(maxsize=None)
def _has(font, char):
    return bytes(font.getmask(char)) != bytes(font.getmask(chr(0xFFFF)))


def _clean(text, font):
    """The text with nothing in it the font would draw as an empty box: the site's
    fonts are Latin subsets."""
    text = " ".join(str(text).translate({0x2192: "›", 0x2264: "<=", 0x2265: ">="}).split())
    return "".join(c for c in text if c == " " or _has(font, c))


def _wrap(text, font, width, limit):
    """Lines no wider than width, and whether all of the text is on them."""
    lines = [""]
    for word in text.split():
        longer = (lines[-1] + " " + word).strip()
        if not lines[-1] or font.getlength(longer) <= width:
            lines[-1] = longer
        elif len(lines) < limit:
            lines.append(word)
        else:
            last = lines[-1]
            while last and font.getlength(last + "…") > width:
                last = last[:-1]
            return lines[:-1] + [last.rstrip(" .,;:-") + "…"], False
    return lines, all(font.getlength(line) <= width for line in lines)


def _fit(title, blurb, width, height):
    """The title at the biggest size at which it and the blurb under it fit the height."""
    body = _font("body", 27)
    blurb = _clean(blurb, body)
    for size, limit in ((96, 1), (84, 2), (74, 2), (66, 3), (58, 3), (50, 3), (44, 4)):
        font, lead = _font("title", size), round(size * 1.08)
        tlines, whole = _wrap(_clean(title, font), font, width, limit)
        room = (height - lead * len(tlines) - 20) // 38
        blines, all_of_it = _wrap(blurb, body, width, max(1, min(4, room))) if blurb else ([], True)
        if whole and all_of_it and len(blines) <= room:
            break
    return font, size, lead, tlines, blines


def _spaced_len(text, font, gap):
    return sum(font.getlength(c) + gap for c in text) - gap


def _spaced(d, xy, text, font, fill, gap):
    """Letterspaced text, which Pillow has no option for."""
    x, y = xy
    for c in text:
        d.text((x, y), c, font=font, fill=fill, anchor="lm")
        x += font.getlength(c) + gap


# ── hardware, at twice the size ──────────────────────────────────────────────

def _box(x0, y0, x1, y1):
    return [x0 * S, y0 * S, x1 * S - 1, y1 * S - 1]


def _gradient(img, box, stops, radius=0, horizontal=False):
    """A box filled with evenly spaced colour stops, as the CSS gradients are."""
    x0, y0, x1, y1 = (v * S for v in box)
    strip = Image.new("RGB", (len(stops), 1))
    strip.putdata([tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)) for c in stops])
    n = x1 - x0 if horizontal else y1 - y0
    # half a stop in from each end, so the box runs from the first colour to the last
    strip = strip.resize((n, 1), Image.Resampling.BILINEAR, box=(.5, 0, len(stops) - .5, 1))
    fill = strip if horizontal else strip.transpose(Image.Transpose.ROTATE_270)
    mask = Image.new("L", (x1 - x0, y1 - y0), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, x1 - x0 - 1, y1 - y0 - 1], radius * S, fill=255)
    img.paste(fill.resize((x1 - x0, y1 - y0)), (x0, y0), mask)


def _dot(d, x, y, r, fill, outline=None):
    d.ellipse([(x - r) * S, (y - r) * S, (x + r) * S, (y + r) * S], fill=fill, outline=outline, width=S)


def _screw(d, x, y, r=6):
    _dot(d, x, y, r + 1, "#050607")
    _dot(d, x, y, r, "#3a4148")
    _dot(d, x - r * .25, y - r * .25, r * .5, "#59626b")
    d.line([(x - r + 2) * S, (y + 2) * S, (x + r - 2) * S, (y - 2) * S], fill="#14171a", width=S + 1)


def _unit_box(i):
    top = RACK[1] + 15 + i * (UNIT_H + UNIT_GAP)
    return RACK[0] + POST + 4, top, RACK[2] - POST - 4, top + UNIT_H


@functools.lru_cache(maxsize=None)
def _hardware(n_units, lit):
    """All of a card that is not text, with every unit of the rack lit or none."""
    img = Image.new("RGB", (W * S, H * S), BG)
    glow = Image.new("L", (W * S, H * S), 0)
    d, g = ImageDraw.Draw(img), ImageDraw.Draw(glow)

    for at in range(64, W, 64):          # the floor's tiles
        d.rectangle(_box(at, 0, at + 1, H), fill="#0e1013")
    for at in range(64, H, 64):
        d.rectangle(_box(0, at, W, at + 1), fill="#0e1013")

    # the header: the mark, and the tape under it
    d.rectangle(_box(0, 0, W, HEAD_H), fill=HEADER)
    d.rectangle(_box(0, HEAD_H, W, HEAD_H + TAPE_H), fill=HAZARD_DARK)
    for x in range(-TAPE_H, W, 28):
        d.polygon([((x + dx) * S, (HEAD_H + dy) * S) for dx, dy in
                   ((0, TAPE_H), (14, TAPE_H), (14 + TAPE_H, 0), (TAPE_H, 0))], fill=HAZARD)
    k, mx, my = 1.75, CARD[0], 22        # favicon.svg and the header's own mark, 28 units wide
    d.rounded_rectangle([(mx + 1 * k) * S, (my + 1 * k) * S, (mx + 27 * k) * S, (my + 27 * k) * S],
                        5 * k * S, outline="#d5dade", width=round(1.6 * k * S))
    for y, led in ((5.4, GREEN), (11.7, GREEN), (18, AMBER)):
        d.rounded_rectangle([(mx + 5.5 * k) * S, (my + y * k) * S, (mx + 22.5 * k) * S, (my + (y + 4.6) * k) * S],
                            1.2 * k * S, fill=TEXT)
        _dot(d, mx + 19.3 * k, my + (y + 2.3) * k, 1.4 * k, "#0f9c50" if led == GREEN else "#d98200")

    # the plate
    _gradient(img, (CARD[0] - 1, CARD[1] - 1, CARD[2] + 1, CARD[3] + 1), [EDGE_HI, EDGE_LO], 7)
    _gradient(img, CARD, ["#2b3036", "#22262b", "#1a1d21"], 6)
    for x in (CARD[0] + 19, CARD[2] - 19):
        for y in (CARD[1] + 21, CARD[3] - 19):
            _screw(d, x, y)

    # the cabinet, its two posts and the units between them
    _gradient(img, (RACK[0] - 1, RACK[1] - 1, RACK[2] + 1, RACK[3] + 1), [EDGE_HI, EDGE_LO], 7)
    d.rounded_rectangle(_box(*RACK), 6 * S, fill="#050607")
    for x in (RACK[0], RACK[2] - POST):
        _gradient(img, (x, RACK[1] + 6, x + POST, RACK[3] - 6), ["#0d0f12", "#22262b", "#191c20", "#0b0d0f"],
                  horizontal=True)
    for i in range(n_units):
        x0, y0, x1, y1 = _unit_box(i)
        _gradient(img, (x0, y0, x1, y1), ["#3a414a", "#2c3238", "#22272c"] if lit else ["#1f2328", "#1a1d21", "#15181b"], 2)
        d.rectangle(_box(x0 + 2, y0, x1 - 2, y0 + 1), fill="#515a64" if lit else "#2b3036")
        for x in range(x0 + 166, x0 + 218, 9):
            d.rounded_rectangle(_box(x, y0 + 15, x + 4, y1 - 15), 2 * S, fill="#0b0d0f")
        for x in (x0 + 236, x0 + 252, x0 + 268):
            _dot(d, x, (y0 + y1) / 2, 5, GREEN if lit else LED_OFF, None if lit else "#191d21")
            if lit:
                _dot(g, x, (y0 + y1) / 2, 8, 150)
        if lit:
            d.rectangle(_box(x0, y0, x0 + 5, y1), fill=GREEN)
        for x in (RACK[0] + POST / 2, RACK[2] - POST / 2):
            _screw(d, x, (y0 + y1) / 2, 5)

    if lit:
        glow = glow.filter(ImageFilter.GaussianBlur(7 * S))
        img.paste(Image.new("RGB", img.size, GREEN), (0, 0), glow.point(lambda v: v * 2 // 3))
        for i in range(n_units):         # the LEDs themselves, over their glow
            x0, y0, _, y1 = _unit_box(i)
            for x in (x0 + 236, x0 + 252, x0 + 268):
                _dot(d, x, (y0 + y1) / 2, 5, GREEN)
    return img.resize((W, H), Image.Resampling.LANCZOS)


# ── a card ───────────────────────────────────────────────────────────────────

def draw(dest, section, kicker, title, blurb="", families=None, lit=None, accent=None, chips=(), upper=True):
    """Writes one card.

    section   the tab of the site's header the page is under
    families  key -> name, one unit of the rack each; lit, the keys that are on
    accent    a colour along the plate's top edge (the language's)
    chips     (label, colour) tags under the text; no colour makes it the tuned tag
    upper     whether the title is capitals, as the site's headings are - an entry's
              name is not
    """
    families = families or {}
    lit = families if lit is None else lit
    img = _hardware(len(families), False).copy()
    on = [i for i, key in enumerate(families) if key in lit]
    for i in on:
        x0, y0, x1, y1 = _unit_box(i)
        box = (x0, y0 - 2, x1, y1 + 2)
        img.paste(_hardware(len(families), True).crop(box), box[:2])
    d = ImageDraw.Draw(img)

    # the header: the name, and the tab of the section
    font = _font("title", 40)
    mid = HEAD_H // 2
    x = CARD[0] + 64
    d.text((x, mid), "Http", font=font, fill=ACCENT, anchor="lm")
    d.text((x + font.getlength("Http"), mid), "Arena", font=font, fill=TEXT, anchor="lm")
    font = _font("label", 24)
    label = section.upper()
    x0 = RACK[2] - 40 - _spaced_len(label, font, 1.5)
    d.rounded_rectangle([x0, 22, RACK[2], HEAD_H - 22], 4, fill=PANEL, outline=LINE)
    _spaced(d, (x0 + 20, mid), label, font, TEXT, 1.5)
    d.rectangle([x0 + 10, HEAD_H - 24, RACK[2] - 10, HEAD_H - 22], fill=GREEN)

    # the units' names
    font = _font("label", 25)
    for i, name in enumerate(families.values()):
        ux, y0, _, y1 = _unit_box(i)
        d.text((ux + 20, (y0 + y1) // 2), name, font=font, fill=TEXT if i in on else OFF, anchor="lm")

    # the language's colour along the plate's top edge, inside its rounded corners
    if accent:
        plate = img.crop((CARD[0], CARD[1] + 7, CARD[2], CARD[1] + 14))
        d.rounded_rectangle([CARD[0], CARD[1], CARD[2] - 1, CARD[1] + 13], 6, fill=accent)
        img.paste(plate, (CARD[0], CARD[1] + 7))

    # the plate: one block of text, in the middle of its height
    x, width = CARD[0] + PAD, CARD[2] - CARD[0] - 2 * PAD
    kicker_h, chips_h = 46, 64 if chips else 0
    title = str(title).upper() if upper else str(title)
    tfont, size, lead, tlines, blines = _fit(title, blurb, width, CARD[3] - CARD[1] - 2 * 34 - kicker_h - chips_h)
    height = kicker_h + lead * len(tlines) + (20 + 38 * len(blines) if blines else 0) + chips_h
    y = (CARD[1] + CARD[3] - height) // 2

    d.ellipse([x, y + 4, x + 11, y + 15], fill=GREEN)
    font, gap = _font("label", 23), 2.4
    kicker = _clean(kicker, font).upper()
    if _spaced_len(kicker, font, gap) > width - 24:
        while _spaced_len(kicker + "…", font, gap) > width - 24:
            kicker = kicker[:-1].rstrip(" ›")
        kicker += "…"
    _spaced(d, (x + 24, y + 10), kicker, font, TEXT_2, gap)
    y += kicker_h
    for line in tlines:
        d.text((x - size // 24, y + lead // 2), line, font=tfont, fill=TEXT, anchor="lm")
        y += lead
    if blines:
        y += 20
        for line in blines:
            d.text((x, y + 19), line, font=_font("body", 27), fill=TEXT_2, anchor="lm")
            y += 38
    y += 24
    font = _font("label", 22)
    for label, color in chips:
        label = _clean(label, font).upper()
        x1 = x + round(_spaced_len(label, font, 1.4)) + (34 if color else 28)
        d.rounded_rectangle([x, y, x1, y + 40], 3, fill=PLATE if color else HAZARD, outline=PLATE_LINE if color else None)
        if color:
            d.rectangle([x, y, x + 5, y + 40], fill=color)
        _spaced(d, (x + (20 if color else 14), y + 20), label, font, TEXT if color else "#16181b", 1.4)
        x = x1 + 12

    d.text((CARD[0], 600), "http-arena.com", font=_font("mono", 23), fill=MUTED, anchor="lm")

    dest.parent.mkdir(parents=True, exist_ok=True)
    # A third of the truecolor file. Maximum coverage, because the default median cut
    # spends the palette on the greys and turns the blue of the name green; the k-means
    # pass takes the colour casts out of the plate's gradient.
    img.quantize(256, Image.Quantize.MAXCOVERAGE, kmeans=1, dither=Image.Dither.NONE).save(dest, "PNG")

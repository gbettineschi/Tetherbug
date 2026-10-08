"""Drawing parts shared by the docs images (make-docs.py) and the store screenshots
(store/make-store.py): xav.ie's palette, the app's own controls, and simple device drawings that
scale with a single size so they look the same at docs and store sizes.

Each function returns an SVG fragment. Everything is drawn for dark mode; make-light.py derives
the light copies by swapping colours, so new colours need a mapping there too.
"""
import math
import re
from pathlib import Path

YELLOW, PURPLE, BG = "#fff17b", "#281336", "#12081a"
GREEN, RED = "#51d136", "#ff6b6b"
SF = "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"
SERIF = "'Sorts Mill Goudy', 'Palatino', Georgia, serif"
MONO = "ui-monospace, Menlo, monospace"
DOCS_FONT = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"  # the docs images' text
# macOS's own menus.
MENU_BG, MENU_EDGE, MENU_TXT, MENU_DIM, MENU_SEP = "#1c1c1e", "#4a4a4c", "#f2f2f2", "#8e8e8e", "#333333"
ACCENT = "#9b59b6"  # the macOS accent colour (purple)


def text(x, y, s, size, color=YELLOW, weight=400, family=None, anchor="start", opacity=1):
    fam = f' font-family="{family}"' if family else ""
    return (f'<text x="{x:g}" y="{y:g}" text-anchor="{anchor}" fill="{color}" font-size="{size:g}" '
            f'font-weight="{weight}" opacity="{opacity:g}"{fam}>{s}</text>\n')


def svg(w, h, title, body, defs="", marker=8, font=DOCS_FONT):
    """A docs image: the rounded dark canvas with an arrowhead marker for `marker-end="url(#arrow)"`."""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" font-family="{font}">\n'
            f'<title>{title}</title>\n'
            f'<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="{marker}" markerHeight="{marker}" '
            f'orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="{YELLOW}"/></marker>{defs}</defs>\n'
            f'<rect width="{w}" height="{h}" rx="24" fill="{BG}"/>\n{body}</svg>\n')


_ids = 0


def _id(prefix):
    global _ids
    _ids += 1
    return f"{prefix}{_ids}"


def link_glyph(cx, cy, color, width=3.0, scale=1.0):
    """macOS's Personal Hotspot mark: two equal chain links, offset diagonally and interlocked
    (each passes over the other once, the one underneath cut away), centred on (cx, cy)."""
    a, b = _id("link"), _id("link")
    sw = width / scale
    gap = sw * 1.25  # half the cutout across the link underneath

    def cut(name, x, y):
        # Everything but a small square around the crossing (even-odd hole).
        return (f'<clipPath id="{name}"><path clip-rule="evenodd" d="M-30 -20 H30 V20 H-30 Z '
                f'M{x - gap:g} {y - gap:g} h{2 * gap:g} v{2 * gap:g} h{-2 * gap:g} Z"/></clipPath>')
    # Where the left link's right side crosses the right link's top, at (6, -3.5), the left link is
    # on top, so the right one is cut; at (-6, 3.5), the right link is on top, so the left one is cut.
    return (f'<g fill="none" stroke="{color}" stroke-width="{sw:g}" transform="translate({cx:g} {cy:g}) scale({scale:g})">'
            f'{cut(a, -6, 3.5)}{cut(b, 6, -3.5)}'
            f'<rect x="-17" y="-9.5" width="23" height="13" rx="6.5" clip-path="url(#{a})"/>'
            f'<rect x="-6" y="-3.5" width="23" height="13" rx="6.5" clip-path="url(#{b})"/></g>')


def wifi_symbol(cx, cy, size, color):
    """macOS's Wi-Fi mark: a 90-degree wedge and two bands of the same circle, sharp-edged, with
    the circle's centre at (cx, cy) and the outer radius `size`."""
    def band(r0, r1):
        a = math.radians(45)
        x0, y0, x1, y1 = r0 * math.sin(a), r0 * math.cos(a), r1 * math.sin(a), r1 * math.cos(a)
        inner = f"L{cx + x0:.2f} {cy - y0:.2f} A{r0:g} {r0:g} 0 0 0 {cx - x0:.2f} {cy - y0:.2f}" if r0 else f"L{cx:g} {cy:g}"
        return f'<path d="M{cx - x1:.2f} {cy - y1:.2f} A{r1:g} {r1:g} 0 0 1 {cx + x1:.2f} {cy - y1:.2f} {inner} Z" fill="{color}"/>'
    k = size / 10
    return band(0, 3 * k) + band(4.4 * k, 6.4 * k) + band(7.8 * k, 10 * k)


# The app's own surfaces (Theme.swift, dark palette): cards, and the switch's trough and knob.
APP_DEFS = (
    f'<linearGradient id="card" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#210f2e"/><stop offset="1" stop-color="#110718"/></linearGradient>'
    '<linearGradient id="knob" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5a5066"/><stop offset="1" stop-color="#3a3344"/></linearGradient>'
    '<linearGradient id="rim" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".6"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/>'
    '<stop offset=".5" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".6"/></linearGradient>'
    # Inner shadows: dark from the top-left (black .45, 4pt blur, 3pt offset), light from the bottom-right.
    '<filter id="trough" x="-10%" y="-20%" width="120%" height="140%">'
    '<feComponentTransfer in="SourceAlpha" result="hole"><feFuncA type="table" tableValues="1 0"/></feComponentTransfer>'
    '<feOffset in="hole" dx="6" dy="6" result="o1"/><feGaussianBlur in="o1" stdDeviation="4" result="b1"/>'
    '<feFlood flood-color="#000" flood-opacity=".45"/><feComposite in2="b1" operator="in"/><feComposite in2="SourceAlpha" operator="in" result="dark"/>'
    '<feOffset in="hole" dx="-2" dy="-2" result="o2"/><feGaussianBlur in="o2" stdDeviation="1.5" result="b2"/>'
    '<feFlood flood-color="#413948"/><feComposite in2="b2" operator="in"/><feComposite in2="SourceAlpha" operator="in" result="light"/>'
    '<feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="dark"/><feMergeNode in="light"/></feMerge></filter>'
    '<filter id="lift" x="-50%" y="-50%" width="200%" height="200%"><feDropShadow dx="3" dy="4" stdDeviation="2.5" flood-color="#000" flood-opacity=".6"/></filter>'
    '<filter id="soft" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="6" dy="10" stdDeviation="12" flood-color="#000" flood-opacity=".5"/></filter>'
)


def switch(x, y, on, width=92):
    """The app's switch (Theme.swift SwitchRow, drawn at 2x for width 92): a sunken trough and a
    raised knob. Needs APP_DEFS."""
    track = "#4a2a63" if on else "#24132f"
    knob = 66 if on else 26
    return (f'<g transform="translate({x:g} {y:g}) scale({width / 92:g})">'
            f'<rect width="92" height="52" rx="26" fill="{track}" filter="url(#trough)"/>'
            f'<g filter="url(#lift)"><circle cx="{knob}" cy="26" r="20" fill="url(#knob)"/>'
            f'<circle cx="{knob}" cy="26" r="18.4" fill="none" stroke="url(#rim)" stroke-width="3.2"/></g></g>')


def card(x, y, w, h):
    """The app's card: its surface gradient, a soft shadow and a faint rim. Needs APP_DEFS."""
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="36" fill="url(#card)" filter="url(#soft)"/>'
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="36" fill="none" stroke="#ffffff" stroke-opacity=".09" stroke-width="2"/>')


def laptop(x, y, w=120, color=YELLOW, stroke=None, inner=""):
    """A MacBook: a screen with rounded top corners and a notch, square at the bottom where a
    trapezoid deck flares out into a slab with rounded ends. `inner` is drawn centred on the screen.
    Everything scales with `w`; a 120-wide laptop is 76 tall."""
    k = w / 120
    h, r, sw = 76 * k, 8 * k, stroke if stroke is not None else 2.5 * k
    o, flare, slant, slab, cr = sw / 2, 13.75 * k, 7 * k, 4.5 * k, 2.5 * k
    bot = y + h
    left, right = x - o, x + w + o
    return (f'<path d="M{x:g} {bot:g} V{y + r:g} a{r:g} {r:g} 0 0 1 {r:g} -{r:g} H{x + w - r:g} a{r:g} {r:g} 0 0 1 {r:g} {r:g} V{bot:g} Z" '
            f'fill="{PURPLE}" stroke="{color}" stroke-width="{sw:g}" stroke-linejoin="round"/>'
            f'<path d="M{x + w / 2 - 10 * k:g} {y:g} h{20 * k:g} v{4 * k:g} a{3 * k:g} {3 * k:g} 0 0 1 -{3 * k:g} {3 * k:g} '
            f'h-{14 * k:g} a{3 * k:g} {3 * k:g} 0 0 1 -{3 * k:g} -{3 * k:g} z" fill="{color}"/>'
            f'<path d="M{left:g} {bot:g} H{right:g} L{right + flare:g} {bot + slant:g} V{bot + slant + slab - cr:g} '
            f'Q{right + flare:g} {bot + slant + slab:g} {right + flare - cr:g} {bot + slant + slab:g} H{left - flare + cr:g} '
            f'Q{left - flare:g} {bot + slant + slab:g} {left - flare:g} {bot + slant + slab - cr:g} V{bot + slant:g} Z" fill="{color}"/>'
            + (f'<g transform="translate({x + w / 2:g} {y + h / 2:g})">{inner}</g>' if inner else "") + "\n")


def phone(x, y, w=64, color=YELLOW, stroke=None, inner=""):
    """A phone: a rounded slab with a camera dot; `inner` is drawn centred on it. A 64-wide phone
    is 112 tall."""
    k = w / 64
    h, sw = 112 * k, stroke if stroke is not None else 2.5 * k
    return (f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="{12 * k:g}" fill="{PURPLE}" stroke="{color}" stroke-width="{sw:g}"/>'
            f'<circle cx="{x + w / 2:g}" cy="{y + 12 * k:g}" r="{4 * k:g}" fill="{color}"/>'
            + (f'<g transform="translate({x + w / 2:g} {y + h / 2:g})">{inner}</g>' if inner else "") + "\n")


def waves(cx, cy, radii=(14, 26, 38), width=2.5, color=YELLOW, flip=False):
    """Radio waves: arcs fading outwards from (cx, cy), opening right (or left when flipped)."""
    sweep = 0 if flip else 1
    return "".join(f'<path d="M{cx:g} {cy - r:g} A{r:g} {r:g} 0 0 {sweep} {cx:g} {cy + r:g}" fill="none" stroke="{color}" '
                   f'stroke-width="{width:g}" stroke-linecap="round" opacity="{1 - i * .25:g}"/>' for i, r in enumerate(radii)) + "\n"


def lock(cx, top, color=YELLOW):
    """A padlock whose body starts at `top`."""
    return (f'<rect x="{cx - 11:g}" y="{top:g}" width="22" height="18" rx="4" fill="{color}"/>'
            f'<path d="M{cx - 7:g} {top:g} V{top - 6:g} a7 7 0 0 1 14 0 V{top:g}" fill="none" stroke="{color}" stroke-width="2.5"/>\n')


def bluetooth(cx, cy, color=YELLOW):
    return (f'<path d="M{cx - 6:g} {cy - 6:g} L{cx + 6:g} {cy + 6:g} L{cx:g} {cy + 12:g} V{cy - 12:g} L{cx + 6:g} {cy - 6:g} L{cx - 6:g} {cy + 6:g}" '
            f'fill="none" stroke="{color}" stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round"/>\n')


def clock(cx, cy, r=26, color=YELLOW):
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{color}" stroke-width="2.5"/>'
            f'<path d="M{cx} {cy - 18} V{cy} L{cx + 12} {cy + 8}" fill="none" stroke="{color}" stroke-width="2.5" stroke-linecap="round"/>\n')


def box(x, y, w, h, label, rx=10, size=13, mono=False, fill=PURPLE, color=YELLOW):
    """A labelled box, as in the docs' component diagrams."""
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{color}" stroke-width="1.5"/>'
            + text(x + w / 2, y + h / 2 + size * .35, label, size, color, family=MONO if mono else None, anchor="middle"))


def wifi_menu(x, y, w, name):
    """macOS's Wi-Fi menu, compact: Wi-Fi switched on, then `name` selected under Personal Hotspot,
    then Other Networks. Laid out for a 172-wide menu (106 tall) and scaled to `w`."""
    k = w / 172
    body = (
        f'<rect width="172" height="106" rx="12" fill="{MENU_BG}" stroke="{MENU_EDGE}" stroke-width="1"/>'
        + text(12, 21, "Wi-Fi", 11, MENU_TXT, 600)
        + f'<rect x="126" y="9" width="34" height="16" rx="8" fill="{ACCENT}"/><rect x="141" y="11" width="17" height="12" rx="6" fill="#f4e8f6"/>'
        + f'<line x1="11" y1="32" x2="161" y2="32" stroke="{MENU_SEP}" stroke-width=".8"/>'
        + text(12, 47, "Personal Hotspot", 8.5, MENU_DIM, 600)
        + f'<circle cx="22" cy="64" r="10" fill="{ACCENT}"/>' + link_glyph(22, 64, "#ffffff", 1.2, .36)
        + text(38, 68, name, 11, MENU_TXT, 400, MONO)
        + f'<line x1="11" y1="80" x2="161" y2="80" stroke="{MENU_SEP}" stroke-width=".8"/>'
        + text(12, 96, "Other Networks", 8.5, MENU_DIM, 600)
        + f'<path d="M156 88 l4 4 l-4 4" fill="none" stroke="{MENU_DIM}" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>'
    )
    return f'<g transform="translate({x:g} {y:g}) scale({k:g})">{body}</g>\n'


def buddy(x, y, width, color):
    """The app's logo, from the generated icon (assets/icon/icon.svg), fitted to `width`."""
    d = re.search(r'<path[^>]* d="([^"]+)"', (Path(__file__).parent / "icon/icon.svg").read_text())[1]
    # The buddy spans x 36..461, y 135..396 of the icon's 512 canvas.
    k = width / 425
    return f'<path d="{d}" fill="{color}" fill-rule="evenodd" transform="translate({x - 36 * k:g} {y - 135 * k:g}) scale({k:g})"/>'

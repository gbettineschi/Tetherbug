#!/usr/bin/env python3
"""Writes the app-store screenshots (1080x1920 SVGs) in this directory.

Each is a headline over a recreation of real macOS UI, drawn to the measurements of actual
screenshots, with placeholder names ("My Pixel Phone") instead of anyone's own.

    python3 assets/store/make-store.py
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
from draw import (ACCENT, APP_DEFS, GREEN, MENU_BG, MENU_DIM, MENU_EDGE, MENU_SEP, MENU_TXT, MONO, PURPLE, SERIF, SF, YELLOW,
                  buddy, card, laptop, link_glyph, phone, switch, text, waves, wifi_symbol)

W, H = 1080, 1920
TXT, DIM, SEP = MENU_TXT, MENU_DIM, MENU_SEP


def page(title, heading, scene, subtitle=None):
    """A store screenshot: a one- or two-line heading (one size and style, bottom-aligned so every
    heading ends on the same line) and an optional subtitle, over the scene, which may run off the
    bottom edge."""
    top = 170
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="{SF}">
<title>{title}</title>
<defs>
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#281336"/><stop offset="1" stop-color="#12081a"/></linearGradient>
<filter id="shadow" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="16" stdDeviation="24" flood-color="#000" flood-opacity=".6"/></filter>
{APP_DEFS}
</defs>
<rect width="{W}" height="{H}" fill="url(#bg)"/>
{"".join(text(W / 2, top + 70 + 82 * (i + 2 - len(heading)), line, 66, YELLOW, 600, SERIF, "middle") for i, line in enumerate(heading))}{text(W / 2, top + 262, subtitle, 33, YELLOW, 400, SF, "middle") if subtitle else ""}<g transform="translate(0 {top + 330})">
{scene}</g>
</svg>
'''


FOREHEAD, BEZEL = 44, 22  # the Mac's black frame: thicker above the screen, where the notch is


def menu_bar(sx, sw, bar=64, items=True):
    """The native menu bar's right end, left to right: battery, Wi-Fi (showing the Personal Hotspot
    link while on one), Control Center, date and time; spacing measured from a real menu bar.
    Returns the SVG and the Wi-Fi item's x, for hanging its menu."""
    out = [f'<g clip-path="url(#bar)"><g filter="url(#frost)">'
           f'<rect x="{sx}" y="-40" width="{sw}" height="{bar + 80}" fill="url(#wallpaper)"/>'
           f'<rect x="{sx}" y="-40" width="{sw}" height="{bar + 80}" fill="url(#ripples)"/></g>'
           f'<rect x="{sx}" y="0" width="{sw}" height="{bar}" fill="#000" fill-opacity=".22"/></g>']
    if not items:
        return out[0], None
    right = sx + sw - 30
    out.append(text(right, 44, "Thu Oct 8  9:41 AM", 28, TXT, 400, SF, "end"))
    cc = right - 245 - 39  # the clock text renders 245 px wide
    out.append(f'<rect x="{cc - 14}" y="18" width="28" height="13" rx="6.5" fill="none" stroke="{TXT}" stroke-width="2.4"/>'
               f'<circle cx="{cc + 7}" cy="24.5" r="4.2" fill="{TXT}"/>'
               f'<rect x="{cc - 14}" y="35" width="28" height="13" rx="6.5" fill="none" stroke="{TXT}" stroke-width="2.4"/>'
               f'<circle cx="{cc - 7}" cy="41.5" r="4.2" fill="{TXT}"/>')
    wifi = cc - 72
    out.append(link_glyph(wifi, 33, TXT, 3.0, 1.25))
    battery = wifi - 90
    out.append(f'<rect x="{battery - 30}" y="21" width="56" height="24" rx="7" fill="none" stroke="{TXT}" stroke-width="2.4"/>'
               f'<rect x="{battery - 26}" y="25" width="48" height="16" rx="4" fill="{TXT}"/>'
               f'<path d="M{battery + 29} 29 a4 4 0 0 1 0 8" fill="{TXT}"/>')
    return "\n".join(out), wifi


def mac_screen(sx, sw, sh, content, items=True, notch=True):
    forehead = FOREHEAD if notch else BEZEL
    """A zoomed-in Mac: wallpaper, menu bar and `content` on a screen inside the black bezel. With
    `notch`, the view is the top middle (thick forehead, camera, notch); without, a corner, where
    the bezel is as thin as at the sides. Parts past the image's edges are simply cut off."""
    bar, wifi = menu_bar(sx, sw, items=items)
    ox, oy, ow, oh = sx - BEZEL, 0, sw + 2 * BEZEL, sh + forehead + BEZEL
    centre = sx + sw / 2
    return (
        '<defs><linearGradient id="wallpaper" x1="1" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#c58be0"/><stop offset=".45" stop-color="#8a4fc4"/><stop offset="1" stop-color="#3b2380"/></linearGradient>'
        '<pattern id="ripples" width="160" height="80" patternUnits="userSpaceOnUse" patternTransform="rotate(-20)">'
        '<path d="M-80 40 Q-40 10 0 40 T80 40 T160 40 T240 40" fill="none" stroke="#fff" stroke-opacity=".14" stroke-width="10"/></pattern>'
        f'<clipPath id="screen"><rect x="{sx}" y="0" width="{sw}" height="{sh}" rx="{56 - BEZEL}"/></clipPath>'
        f'<clipPath id="bar"><rect x="{sx}" y="0" width="{sw}" height="64"/></clipPath>'
        '<filter id="frost" x="-5%" y="-50%" width="110%" height="200%"><feGaussianBlur stdDeviation="14"/></filter></defs>\n'
        # The bezel: a black frame with a faint aluminium edge.
        f'<rect x="{ox}" y="{oy}" width="{ow}" height="{oh}" rx="56" fill="#0b0b0c"/>'
        f'<rect x="{ox + 1.5}" y="{oy + 1.5}" width="{ow - 3}" height="{oh - 3}" rx="55" fill="none" stroke="#5a5a60" stroke-width="3"/>\n'
        f'<g transform="translate(0 {forehead})"><g clip-path="url(#screen)">'
        f'<rect x="{sx}" y="0" width="{sw}" height="{sh}" fill="url(#wallpaper)"/>'
        f'<rect x="{sx}" y="0" width="{sw}" height="{sh}" fill="url(#ripples)"/>\n'
        f'{bar}\n{content(wifi)}</g>'
        # The top middle: the camera in the forehead, and the notch hanging into the menu bar.
        + (f'<path d="M{centre - 100} 0 H{centre + 100} V22 a14 14 0 0 1 -14 14 H{centre - 86} a14 14 0 0 1 -14 -14 Z" fill="#0b0b0c"/>'
           f'<circle cx="{centre}" cy="-20" r="5" fill="#1c1c22"/><circle cx="{centre}" cy="-20" r="2" fill="#2e3550"/>' if notch else "")
        + '</g>\n'
    )


def wifi_menu_scene():
    """The Wi-Fi menu open under the menu bar, as on macOS 26. No known networks: Tetherbug only
    asks for the hotspot when none is around. The Mac runs off the left and bottom edges."""
    sx, sw, sh, bar = -260, 1300, 2000, 64

    def menu(wifi):
        # As wide as the real menu, hung under the Wi-Fi icon but kept on screen.
        mw, mh = 612, 348
        mx = max(sx + 24, wifi - 486)
        rows = (
            text(28, 50, "Wi-Fi", 27, TXT, 600)
            + f'<rect x="478" y="16" width="108" height="48" rx="24" fill="{ACCENT}"/><rect x="518" y="20" width="64" height="40" rx="20" fill="#f4e8f6"/>'
            + f'<line x1="26" y1="83" x2="586" y2="83" stroke="{SEP}" stroke-width="1.5"/>'
            + text(28, 126, "Personal Hotspot", 23, DIM, 600)
            + f'<circle cx="52" cy="171" r="26" fill="{ACCENT}"/>' + link_glyph(52, 171, "#ffffff", 2.8, 0.82)
            + text(94, 181, "My Pixel Phone", 26, TXT, 500)
            + f'<line x1="26" y1="213" x2="586" y2="213" stroke="{SEP}" stroke-width="1.5"/>'
            + text(28, 256, "Other Networks", 23, DIM, 600)
            + f'<path d="M574 238 l9 10 l-9 10" fill="none" stroke="{DIM}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>'
            + f'<line x1="26" y1="279" x2="586" y2="279" stroke="{SEP}" stroke-width="1.5"/>'
            + text(28, 322, "Wi-Fi Settings…", 25, TXT)
        )
        return (f'<g transform="translate({mx} {bar + 6})" filter="url(#shadow)">'
                f'<rect x="0" y="0" width="{mw}" height="{mh}" rx="30" fill="{MENU_BG}" fill-opacity=".97" stroke="{MENU_EDGE}" stroke-width="1.5"/>'
                f'{rows}</g>')

    return mac_screen(sx, sw, sh, menu, notch=False)





def automatic_scene():
    """Wi-Fi gone, the phone's hotspot comes on by itself, the Mac joins it."""
    wifi_off = wifi_symbol(0, 30, 56, YELLOW) + '<path d="M-46 -40 L46 48" stroke="#ff6b6b" stroke-width="9" stroke-linecap="round"/>'
    toggle = switch(-46, -16, True)
    link = link_glyph(0, 4, YELLOW, 7, 2.6)
    def step(y, n, line1, line2):
        return (f'<circle cx="96" cy="{y - 12}" r="26" fill="{GREEN}"/>' + text(96, y - 1, n, 30, "#12081a", 700, SF, "middle")
                + text(140, y, line1, 38, YELLOW, 600, SF) + text(140, y + 44, line2, 29, YELLOW, 400, SF, "start", .7))
    def arrow(y1, y2):
        return f'<path d="M850 {y1} V{y2}" stroke="{YELLOW}" stroke-width="5" stroke-dasharray="4 14" stroke-linecap="round" opacity=".6"/>'
    out = (
        laptop(700, 60, 300, stroke=6, inner=wifi_off) + step(150, "1", "Wi-Fi disconnects", "and no known network is around")
        + arrow(320, 510)
        + phone(775, 530, 150, stroke=6, inner=toggle) + waves(950, 670, (26, 48, 70), 6)
        + step(650, "2", "Your phone's hotspot", "turns on by itself, over Bluetooth")
        + arrow(820, 1040)
        + laptop(700, 1060, 300, stroke=6, inner=link) + step(1150, "3", "Your Mac joins it", "as a Personal Hotspot")
    )
    return out







def window_scene():
    """Tetherbug's Mac window, measured from a real screenshot: header, status card, settings card."""
    TITLE = "'Palatino', 'Sorts Mill Goudy', Georgia, serif"
    w, h = 1000, 936
    ox = (W - w) / 2
    out = [
           f'<g transform="translate({ox} 0)">',  # placed by window_scene
           f'<rect x="0" y="0" width="{w}" height="{h}" rx="48" fill="#12081a" filter="url(#shadow)"/>',
           # The window's rim (Theme.swift WindowSurface): light top-left to dark bottom-right, 1.5pt,
           # with a faint dark line just inside.
           '<linearGradient id="windowRim" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/>'
           '<stop offset=".5" stop-color="#fff" stop-opacity=".04"/><stop offset="1" stop-color="#000" stop-opacity=".55"/></linearGradient>',
           f'<rect x="-1" y="-1" width="{w + 2}" height="{h + 2}" rx="49" fill="none" stroke="#ffffff" stroke-opacity=".36" stroke-width="2.5"/>',
           f'<rect x="1.5" y="1.5" width="{w - 3}" height="{h - 3}" rx="46.5" fill="none" stroke="url(#windowRim)" stroke-width="3"/>',
           f'<rect x="4" y="4" width="{w - 8}" height="{h - 8}" rx="44" fill="none" stroke="#000" stroke-opacity=".25" stroke-width="2"/>',
           text(36, 100, "Tetherbug", 70, YELLOW, 700, TITLE),
           text(36, 148, "Instant Hotspot for your Mac", 26, YELLOW, 400, SF, "start", .85),
           buddy(614, 46, 196, YELLOW)]
    for cx, glyph in ((866, '<path d="M-9 0 H9" stroke-width="3"/>'), (938, '<path d="M-8 -8 L8 8 M8 -8 L-8 8" stroke-width="3"/>')):
        out.append(f'<circle cx="{cx}" cy="71" r="26" fill="url(#card)" stroke="#ffffff" stroke-opacity=".1" stroke-width="2"/>'
                   f'<g transform="translate({cx} 71)" stroke="{YELLOW}" stroke-linecap="round" opacity=".8">{glyph}</g>')
    # Status card.
    out.append(card(38, 202, 924, 318))
    out.append(f'<g transform="translate(92 250)" fill="none" stroke="{YELLOW}" stroke-width="2.6" stroke-linecap="round">'
               '<rect x="-8" y="-14" width="16" height="28" rx="3.5"/>'
               '<path d="M-15 -7 a10 10 0 0 0 0 14 M15 -7 a10 10 0 0 1 0 14 M-21 -11 a16 16 0 0 0 0 22 M21 -11 a16 16 0 0 1 0 22" opacity=".8"/></g>')
    out.append(text(134, 260, "My Pixel Phone is connected", 26, YELLOW, 700))
    out.append(text(68, 322, "Hotspot", 25, YELLOW) + switch(840, 288, True))
    out.append(text(68, 385, "Network", 25, YELLOW) + text(690, 385, "My Pixel Phone", 25, YELLOW, 400, MONO, "end"))
    out.append(text(68, 437, "Password", 25, YELLOW)
               + f'<text x="690" y="437" font-family="{MONO}" font-size="25" font-style="italic" fill="{YELLOW}" text-anchor="end" opacity=".6">Hidden</text>'
               + text(712, 437, "Show", 25, GREEN) + text(800, 437, "Copy", 25, GREEN))
    out.append(text(68, 484, "Cell signal 3/4", 20, YELLOW, 400, SF, "start", .7))
    # Settings card.
    out.append(card(38, 558, 924, 340))
    out.append(text(68, 618, "Settings", 34, YELLOW, 700, TITLE))
    out.append(text(68, 683, "Turn on hotspot when Wi-Fi is disconnected", 25, YELLOW) + switch(840, 648, True))
    out.append(text(100, 755, "After disconnected for", 25, YELLOW)
               + '<rect x="388" y="720" width="134" height="50" rx="20" fill="url(#card)" stroke="#ffffff" stroke-opacity=".09" stroke-width="2"/>'
               + text(504, 755, "5", 25, YELLOW, 400, MONO, "end") + text(540, 755, "sec", 25, YELLOW, 400, SF, "start", .7))
    out.append(text(68, 817, "Run in the background", 25, YELLOW) + switch(840, 782, True))
    out.append(text(68, 864, "Starts at login and keeps working when this window is closed.", 20, YELLOW, 400, SF, "start", .7))
    out.append("</g>")
    window = "\n".join(out) + "\n"
    # The top middle of the Mac: the screen runs off both sides and the bottom, the window sits
    # centred below the menu bar.
    return mac_screen(W / 2 - 1000, 2000, 2000, lambda wifi: f'<g transform="translate(0 104)">{window}</g>', items=False)




def android_scene(screenshot, top_colour):
    """A Pixel-style phone (black bezel, punch-hole camera, side buttons) showing one of the
    Android screenshots that Gradle renders on the JVM (android/), under a drawn status bar: the
    renderer has no system bars. `top_colour` is the screenshot's top edge, for the status bar."""
    shot_w, shot_h = 1078, 2399  # android/*.png
    sw = 560
    sh = sw * shot_h / shot_w
    bar, bezel = 56, 18
    w, h = sw + 2 * bezel, sh + bar + 2 * bezel
    x, y = (W - w) / 2, 0
    sx, sy = x + bezel, y + bezel
    clip = '<clipPath id="phoneScreen"><rect x="{:g}" y="{:g}" width="{:g}" height="{:g}" rx="54"/></clipPath>'.format(sx, sy, sw, sh + bar)
    status = (text(sx + 40, sy + 37, "9:41", 24, "#f2f2f2", 600)
              # Signal bars and a battery at the right.
              + "".join(f'<rect x="{sx + sw - 120 + i * 9:g}" y="{sy + 34 - 5 * (i + 1):g}" width="6" height="{5 * (i + 1)}" rx="1.5" fill="#f2f2f2"/>' for i in range(4))
              + f'<rect x="{sx + sw - 72:g}" y="{sy + 19:g}" width="32" height="17" rx="5" fill="none" stroke="#f2f2f2" stroke-width="2"/>'
              + f'<rect x="{sx + sw - 69:g}" y="{sy + 22:g}" width="22" height="11" rx="2.5" fill="#f2f2f2"/>'
              + f'<rect x="{sx + sw - 38:g}" y="{sy + 24:g}" width="3" height="7" rx="1.5" fill="#f2f2f2"/>')
    return (
        f'<defs>{clip}</defs>'
        # Side buttons: power, then volume.
        + f'<rect x="{x + w - 2:g}" y="{y + 300:g}" width="8" height="110" rx="4" fill="#2a2a2e"/>'
        + f'<rect x="{x + w - 2:g}" y="{y + 470:g}" width="8" height="190" rx="4" fill="#2a2a2e"/>'
        + f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="72" fill="#0b0b0c" filter="url(#shadow)"/>'
        + f'<rect x="{x + 1.5:g}" y="{y + 1.5:g}" width="{w - 3:g}" height="{h - 3:g}" rx="70.5" fill="none" stroke="#5a5a60" stroke-width="3"/>'
        + '<g clip-path="url(#phoneScreen)">'
        + f'<rect x="{sx:g}" y="{sy:g}" width="{sw:g}" height="{bar}" fill="{top_colour}"/>{status}'
        + f'<image href="{screenshot}" x="{sx:g}" y="{sy + bar:g}" width="{sw:g}" height="{sh:g}"/></g>'
        + f'<circle cx="{W / 2:g}" cy="{sy + bar / 2:g}" r="12" fill="#0b0b0c"/>\n'
    )


here = Path(__file__).parent
(here / "1-wifi-menu.svg").write_text(page(
    "The Mac's Wi-Fi menu lists the Android phone's hotspot, My Pixel Phone, under Personal Hotspot.",
    ("Your Android hotspot,", "right in your Mac's Wi-Fi menu."),
    wifi_menu_scene(),
    "It shows up as a Personal Hotspot, just like an iPhone's.",
))
(here / "2-automatic.svg").write_text(page(
    "When the Mac's Wi-Fi disconnects, the phone's hotspot turns on by itself over Bluetooth and the Mac joins it, like Instant Hotspot with an iPhone.",
    ("No Wi-Fi?",),
    automatic_scene(),
    "No need to reach for your phone.",
))
(here / "3-mac-window.svg").write_text(page(
    "Tetherbug's Mac window shows the connected phone, a switch for its hotspot, the network and its settings.",
    ("Control it", "from your Mac."),
    window_scene(),
))

def feature_graphic(light=False):
    """Play's 1024x500 feature graphic: the Mac's Wi-Fi menu (image 1's scene) on the left, the
    top half of the Android app (image 4's phone, larger, running off the bottom) on the right, and
    the bug between them. `light` is the README's light-theme copy: a light background and a
    purple bug."""
    fw, fh = 1024, 500
    mac = wifi_menu_scene()          # its menu, menu bar and bezel corner span x 150..1062
    if light:
        # macOS in light mode: the menu and menu bar text, in make-light.py's light pairs for them.
        swaps = {MENU_BG: "#ececec", MENU_TXT: "#1c1c1e", MENU_EDGE: "#c8c8c8", MENU_SEP: "#d8d8d8"}
        mac = "".join(swaps.get(part, part) for part in re.split(f"({'|'.join(swaps)})", mac))
        # The frosted menu bar lightens what's behind it instead of darkening it.
        mac = mac.replace('fill="#000" fill-opacity=".22"', 'fill="#fff" fill-opacity=".35"')
    android = android_scene("android/1-setup.png", "#12081a")  # a phone centred on x 540
    middle = buddy(fw / 2 - 105, 185, 210, PURPLE if light else YELLOW)
    top, bottom = ("#f7f6f2", "#e7e6e0") if light else ("#281336", "#12081a")
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {fw} {fh}" font-family="{SF}">
<title>Tetherbug: a Mac's Wi-Fi menu showing the phone's Personal Hotspot, the Tetherbug logo, and the Android app.</title>
<defs>
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>
<filter id="shadow" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="16" stdDeviation="24" flood-color="#000" flood-opacity=".6"/></filter>
{APP_DEFS}
</defs>
<rect width="{fw}" height="{fh}" fill="url(#bg)"/>
<g transform="translate(-58 110) scale(.42)">{mac}</g>
<g transform="translate(523 60) scale(.55)">{android}</g>
{middle}</svg>
'''

(here / "4-android-app.svg").write_text(page(
    "The Tetherbug Android app's setup checklist, every step done: Bluetooth and notifications, Shizuku, the background service and a paired Mac.",
    ("Set it up once", "on your phone."),
    android_scene("android/1-setup.png", "#12081a"),
))
(here / "feature-graphic.svg").write_text(feature_graphic())
(here / "feature-graphic-light.svg").write_text(feature_graphic(light=True))

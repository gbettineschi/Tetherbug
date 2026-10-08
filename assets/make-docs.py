#!/usr/bin/env python3
"""Writes the docs' images (dark mode) into images/, composed from the parts in draw.py. Edit
here, not the SVGs; build.py runs this, the store screenshots and make-light.py.

    python3 assets/build.py
"""
from pathlib import Path

from draw import (APP_DEFS, BG, GREEN, MONO, PURPLE, RED, YELLOW, bluetooth, box, clock, laptop, lock, phone,
                  svg, switch, text, waves, wifi_menu, wifi_symbol)

IMAGES = Path(__file__).parent / "images"


def blocked(cx, cy):
    """A red no-entry circle with an X."""
    return (f'<circle cx="{cx}" cy="{cy}" r="10" fill="{BG}" stroke="{RED}" stroke-width="2"/>'
            f'<path d="M{cx - 4.5} {cy - 4.5} L{cx + 4.5} {cy + 4.5} M{cx + 4.5} {cy - 4.5} L{cx - 4.5} {cy + 4.5}" '
            f'stroke="{RED}" stroke-width="2" stroke-linecap="round"/>\n')


def step_pair():
    evil = (f'<path d="M-13 -9 L-5 -5 M13 -9 L5 -5" stroke="{RED}" stroke-width="2" stroke-linecap="round"/>'
            f'<circle cx="-7" cy="-1" r="2" fill="{RED}"/><circle cx="7" cy="-1" r="2" fill="{RED}"/>'
            f'<path d="M-8 12 Q0 5 8 12" fill="none" stroke="{RED}" stroke-width="2" stroke-linecap="round"/>')
    return svg(600, 256, "Step 1: only a Mac paired with the phone can read its status or send commands",
               phone(56, 54) + waves(130, 110) + text(88, 196, "Phone", 13, opacity=.8, anchor="middle")
               + f'<path d="M190 92 H372" stroke="{YELLOW}" stroke-width="2" stroke-dasharray="6 6"/>' + lock(281, 84)
               + text(281, 132, "encrypted, bonded", 12, GREEN, anchor="middle")
               + laptop(392, 54) + text(452, 160, "your paired Mac ✓", 13, anchor="middle")
               + f'<path d="M190 138 Q 236 206 308 210" fill="none" stroke="{RED}" stroke-width="2" stroke-dasharray="4 6"/>'
               + blocked(320, 210) + laptop(352, 186, 64, RED, 2, evil) + text(432, 214, "other devices ✗", 13, RED))


def step_wifi_drops():
    wifi_off = wifi_symbol(0, 8, 28, YELLOW) + f'<path d="M-24 -22 L24 12" stroke="{RED}" stroke-width="3" stroke-linecap="round"/>'
    return svg(600, 220, "Step 2: when Wi-Fi stays disconnected for 5 seconds the Mac asks the phone for its hotspot; "
                         "once nothing has been connected for 5 minutes, Android turns it off again",
               laptop(40, 64, inner=wifi_off) + text(100, 188, "Wi-Fi disconnected", 13, opacity=.8, anchor="middle")
               + clock(246, 102) + text(246, 150, "wait 5 s", 13, anchor="middle")
               + text(246, 168, "for a known network", 11, opacity=.7, anchor="middle")
               + f'<path d="M290 102 H436" stroke="{YELLOW}" stroke-width="2" marker-end="url(#arrow)"/>'
               + text(363, 92, "enable", 14, weight=600, anchor="middle")
               + phone(456, 46) + text(488, 184, "Phone", 13, opacity=.8, anchor="middle")
               + text(363, 202, "unused for 5 min → Android turns it off", 12, GREEN, anchor="middle"))


def step_hotspot_on():
    def field(x, w, top, sub, marker=False):
        fg = PURPLE if marker else YELLOW
        return (f'<rect x="{x}" y="78" width="{w}" height="44" rx="8" fill="{YELLOW if marker else PURPLE}"/>'
                + text(x + w / 2, 96, top, 11.5, fg, 600 if marker else 400, anchor="middle")
                + text(x + w / 2, 112, sub, 10.5, fg, family=MONO, anchor="middle", opacity=1 if marker else .7))
    hotspot = switch(-18, -18, True, 36) + text(0, 20, "Hotspot", 10, opacity=.8, anchor="middle")
    return svg(600, 220, "Step 3: the phone turns its hotspot on through Shizuku, its Wi-Fi beacon carries Apple's Personal "
                         "Hotspot marker, and the Mac's Wi-Fi menu lists it as a Personal Hotspot",
               phone(40, 44, inner=hotspot) + waves(114, 100, (12, 22, 32))
               + text(72, 184, "on via Shizuku", 12, anchor="middle") + text(72, 200, "(no root)", 11, opacity=.7, anchor="middle")
               + field(164, 70, "SSID", "My Hotspot") + field(238, 56, "Security", "WPA2") + field(298, 92, "Apple marker", "00:17:F2 06", True)
               + text(277, 146, "Wi-Fi beacon", 12, opacity=.8, anchor="middle")
               + f'<path d="M396 100 H406" stroke="{YELLOW}" stroke-width="2" marker-end="url(#arrow)"/>'
               + wifi_menu(410, 42, 172, "My Hotspot")
               + text(496, 168, "macOS sees a", 12, anchor="middle") + text(496, 184, "Personal Hotspot", 12, anchor="middle"),
               defs=APP_DEFS)


def pieces_mac():
    line = f'fill="none" stroke="{YELLOW}" stroke-width="1.8"'
    return svg(720, 240, "On the Mac: the Tetherbug window and the tetherbug CLI talk to the background agent over one "
                         "local socket, agent.sock; the agent keeps the Bluetooth LE link to the phone",
               f'<rect x="24" y="24" width="540" height="192" rx="16" fill="none" stroke="{GREEN}" stroke-width="1.5"/>'
               + text(42, 50, "Mac", 14, GREEN, 600)
               + box(48, 68, 170, 40, "Tetherbug window") + box(48, 148, 170, 40, "tetherbug CLI")
               + box(262, 110, 108, 32, "agent.sock", rx=16, mono=True)
               + f'<path d="M218 88 H230 a8 8 0 0 1 8 8 V118 a8 8 0 0 0 8 8" {line}/>'
               + f'<path d="M218 168 H230 a8 8 0 0 0 8 -8 V134 a8 8 0 0 1 8 -8" {line}/>'
               + f'<path d="M246 126 H260" {line} marker-end="url(#arrow)"/>'
               + box(404, 106, 140, 40, "Background agent") + f'<path d="M370 126 H402" {line} marker-end="url(#arrow)"/>'
               + f'<path d="M574 126 H636" {line} stroke-dasharray="6 5" marker-end="url(#arrow)" marker-start="url(#arrow)"/>'
               + text(605, 116, "BLE", 12, GREEN, anchor="middle")
               + phone(638, 87, 44, stroke=2.2) + text(660, 190, "Phone", 12, opacity=.8, anchor="middle"))


def pieces_phone():
    line = f'fill="none" stroke="{YELLOW}" stroke-width="1.8"'
    return svg(720, 240, "On the phone: the Tetherbug service answers the Mac over Bluetooth LE and starts or stops the "
                         "hotspot through Shizuku and Android's tethering and Wi-Fi services",
               laptop(36, 98, 84, stroke=2.2) + text(78, 190, "Mac", 12, opacity=.8, anchor="middle")
               + f'<path d="M134 126 H214" {line} stroke-dasharray="6 5" marker-end="url(#arrow)" marker-start="url(#arrow)"/>'
               + text(174, 116, "BLE", 12, GREEN, anchor="middle")
               + f'<rect x="224" y="24" width="472" height="192" rx="16" fill="none" stroke="{GREEN}" stroke-width="1.5"/>'
               + text(242, 50, "Android phone", 14, GREEN, 600)
               + box(248, 106, 140, 40, "Tetherbug service") + f'<path d="M388 126 H418" {line} marker-end="url(#arrow)"/>'
               + box(420, 106, 96, 40, "Shizuku") + f'<path d="M516 126 H546" {line} marker-end="url(#arrow)"/>'
               + box(548, 106, 128, 40, "Tethering + Wi-Fi")
               + text(462, 176, "starts and stops the hotspot without root", 12, opacity=.7, anchor="middle"))


def pairing():
    return svg(620, 256, "Pairing: with Bluetooth settings open on the Mac, pick it under Pair new device on the phone and "
                         "confirm the same code on both within 30 seconds; the bond carries the keys for Tetherbug's encrypted link",
               laptop(60, 58, inner=bluetooth(0, -2)) + waves(196, 96, (12, 21, 30), 2.2)
               + phone(486, 46) + waves(474, 102, (12, 21, 30), 2.2, flip=True)
               + f'<rect x="280" y="64" width="100" height="28" rx="8" fill="{YELLOW}"/>'
               + text(330, 83, "482 913", 14, PURPLE, 600, MONO, "middle")
               + text(330, 112, "same code on both", 12, anchor="middle") + text(330, 128, "confirm within 30 s", 11, opacity=.7, anchor="middle")
               + text(120, 176, "System Settings → Bluetooth", 12, anchor="middle") + text(518, 182, "Pair new device", 12, anchor="middle")
               + f'<path d="M200 206 H460" stroke="{YELLOW}" stroke-width="2" stroke-dasharray="6 6"/>' + lock(330, 198)
               + text(330, 236, "bonded: the keys for Tetherbug's encrypted link", 12, GREEN, anchor="middle"))


def beacon():
    def field(x, w, top, sub, marker=False, sub_mono=False):
        fg = PURPLE if marker else YELLOW
        return (f'<rect x="{x}" y="64" width="{w}" height="56" rx="10" fill="{YELLOW if marker else PURPLE}"/>'
                + text(x + w / 2, 89 if marker else 90, top, 13, fg, 600 if marker else 400, anchor="middle")
                + text(x + w / 2, 107 if marker else 108, sub, 12 if marker else 13, fg, family=MONO if sub_mono else None,
                       anchor="middle", opacity=1 if marker else .7))
    return svg(880, 320, "How macOS spots a Personal Hotspot: an Apple vendor element in the Wi-Fi beacon",
               text(32, 44, "Phone's Wi-Fi beacon", 18, weight=600)
               + field(32, 96, "SSID", '"My Hotspot"', sub_mono=True) + field(136, 96, "Security", "WPA2")
               + field(240, 160, "Apple vendor element", "DD 0A 00:17:F2 06 …", True, True)
               + text(320, 142, "added by Tetherbug (Android 13+)", 12, GREEN, anchor="middle")
               + f'<path d="M320 156 C 320 214, 520 214, 568 150" fill="none" stroke="{YELLOW}" stroke-width="2" marker-end="url(#arrow)"/>'
               + text(576, 44, "macOS Wi-Fi menu", 18, weight=600) + wifi_menu(576, 60, 220, "My Hotspot")
               + text(576, 226, "isPersonalHotspot = true, so macOS:", 13, weight=600)
               + text(588, 250, "• shows the link icon", 13) + text(588, 272, "• treats the connection as metered", 13)
               + text(588, 294, "• applies hotspot auto-join rules", 13))


def wifi_drops():
    """The when-Wi-Fi-disconnects sequence: lifelines, messages and notes."""
    cols = {"Mac": 150, "Phone": 390, "Shizuku": 600}
    names = {"Mac": "Mac agent", "Phone": "Android app", "Shizuku": "Shizuku"}
    rows = [
        ("note", "Mac", "Wi-Fi disconnected"),
        ("note", "Mac", "wait 5 s for a known network"),
        ("msg", "Mac", "Phone", "enable (encrypted BLE write)", False),
        ("msg", "Phone", "Shizuku", "start tethering", False),
        ("msg", "Shizuku", "Phone", "hotspot on", True),
        ("msg", "Phone", "Mac", f'status: on, ssid <tspan font-family="{MONO}">"My Hotspot"</tspan>', True),
        ("note", "Mac", "macOS joins it as a Personal Hotspot"),
        ("note", "Mac", "later: back on regular Wi-Fi"),
        ("note", "Phone", "nothing connected for 5 min"),
        ("note", "Phone", "Android turns the hotspot off"),
    ]
    top, box_h, step = 24, 44, 48
    first = top + box_h + 34
    bottom = first + step * (len(rows) - 1) + 30
    h = bottom + box_h + 24
    out = ['<g transform="translate(31 0)">']
    out += [f'<line x1="{x}" y1="{top + box_h}" x2="{x}" y2="{bottom}" stroke="{YELLOW}" stroke-width="1.5" opacity=".6"/>' for x in cols.values()]
    for name, x in cols.items():
        for y in (top, bottom):
            out.append(f'<rect x="{x - 75}" y="{y}" width="150" height="{box_h}" rx="10" fill="{PURPLE}" stroke="{YELLOW}" stroke-width="1.5"/>'
                       + text(x, y + box_h / 2 + 5, names[name], 14, anchor="middle"))
    for i, row in enumerate(rows):
        y = first + step * i
        if row[0] == "note":
            _, col, label = row
            w = max(150, len(label) * 7.4 + 32)
            out.append(f'<rect x="{cols[col] - w / 2:g}" y="{y - 17}" width="{w:g}" height="34" rx="8" fill="{PURPLE}" stroke="{GREEN}" stroke-width="1.5"/>'
                       + text(cols[col], y + 5, label, 13, GREEN, anchor="middle"))
        else:
            _, a, b, label, dashed = row
            xa, xb = cols[a], cols[b]
            end = xb - 4 if xb > xa else xb + 4
            dash = ' stroke-dasharray="6 5"' if dashed else ""
            out.append(f'<path d="M{xa} {y + 8} H{end}" stroke="{YELLOW}" stroke-width="1.8"{dash} marker-end="url(#arrow)"/>'
                       + text((xa + xb) / 2, y - 2, label, 13, anchor="middle"))
    out.append("</g>")
    return svg(738, h, "When Wi-Fi disconnects: the Mac agent waits 5 seconds for a known network, then asks the Android app to "
                       "enable the hotspot over encrypted BLE; the app starts tethering through Shizuku and reports the hotspot on "
                       "with its SSID, and macOS joins it as a Personal Hotspot. Once the Mac is back on regular Wi-Fi and nothing "
                       "has been connected for 5 minutes, Android turns the hotspot off.",
               "\n".join(out) + "\n", marker=7)


for name, draw in [("step-pair", step_pair), ("step-wifi-drops", step_wifi_drops), ("step-hotspot-on", step_hotspot_on),
                   ("pieces-mac", pieces_mac), ("pieces-phone", pieces_phone), ("pairing", pairing), ("beacon", beacon),
                   ("wifi-drops", wifi_drops)]:
    (IMAGES / f"{name}.svg").write_text(draw())

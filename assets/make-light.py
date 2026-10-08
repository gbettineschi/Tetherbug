#!/usr/bin/env python3
"""Writes a light-mode copy (<name>-light.svg) of every dark SVG in this directory.

The dark SVGs are the source; the README shows the light copies to GitHub's light theme through
<picture>. build.py runs this after the generators:

    python3 assets/build.py
"""
from pathlib import Path

# xav.ie dark palette -> light palette, matched by role.
LIGHT = {
    "#12081a": "#f7f6f2",  # background
    "#281336": "#e7e6e0",  # card / screen surface (also the text on yellow pills)
    "#fff17b": "#281336",  # foreground: line art and text
    "#51d136": "#257015",  # accent
    "#ff6b6b": "#b3261e",  # refused / error
    # The app's switch, in its light-theme colours.
    "#4a2a63": "#9e8aaf",  # trough, on
    "#24132f": "#a9a8a1",  # trough, off
    "#413948": "#cbcac5",  # trough highlight
    "#5a5066": "#c3c2bc",  # knob, top
    "#3a3344": "#b3b2ab",  # knob, bottom
    # macOS's menus, in light mode.
    "#1c1c1e": "#ececec",  # menu
    "#f2f2f2": "#1c1c1e",  # menu text
    "#4a4a4c": "#c8c8c8",  # menu edge
    "#333333": "#d8d8d8",  # menu separators
}

here = Path(__file__).parent / "images"
for src in sorted(here.glob("*.svg")):
    if src.stem.endswith("-light"):
        continue
    svg = src.read_text()
    # One pass through placeholders so a swapped colour isn't swapped again.
    for i, dark in enumerate(LIGHT):
        svg = svg.replace(dark, f"@{i}@")
    for i, light in enumerate(LIGHT.values()):
        svg = svg.replace(f"@{i}@", light)
    src.with_name(f"{src.stem}-light.svg").write_text(svg)
    print(src.with_name(f"{src.stem}-light.svg").name)

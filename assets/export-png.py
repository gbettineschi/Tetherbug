#!/usr/bin/env python3
"""Renders the store images to the PNGs the stores take, into fastlane/metadata (which F-Droid
and IzzyOnDroid read from the repo, and the release workflow uploads to Play): the phone
screenshots and feature graphic from assets/store/, and the 512px icon from assets/icon/. Also
the README's hero image, in assets/readme/.

Run after build.py whenever a store image changes, on a Mac (the images use Apple's fonts):

    python3 assets/export-png.py
"""
import shutil
import subprocess
import tempfile
from pathlib import Path

here = Path(__file__).parent
images = here.parent / "fastlane/metadata/android/en-US/images"
rsvg = ["rsvg-convert"] if shutil.which("rsvg-convert") else ["nix", "run", "nixpkgs#librsvg", "--"]


def render(svg, png, *size):
    png.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([*rsvg, *size, str(svg), "-o", str(png)], check=True)
    print(png.relative_to(here.parent))


screenshots = sorted(p for p in (here / "store").glob("[0-9]-*.svg"))
for old in (images / "phoneScreenshots").glob("*.png"):
    old.unlink()
for i, svg in enumerate(screenshots, 1):
    render(svg, images / "phoneScreenshots" / f"{i}.png")
render(here / "store/feature-graphic.svg", images / "featureGraphic.png")
# Play rounds the store icon itself, so it takes a full square: icon.svg's circle filled out.
with tempfile.NamedTemporaryFile("w", suffix=".svg") as square:
    square.write((here / "icon/icon.svg").read_text().replace('<circle cx="256" cy="256" r="256"', '<rect width="512" height="512"', 1))
    square.flush()
    render(Path(square.name), images / "icon.png", "-w", "512", "-h", "512")
# The README's hero: the feature graphic, for each theme. PNG, since GitHub won't load the phone's
# screenshot from inside an SVG shown as an image.
render(here / "store/feature-graphic.svg", here / "readme/hero.png")
render(here / "store/feature-graphic-light.svg", here / "readme/hero-light.png")

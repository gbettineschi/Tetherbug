#!/usr/bin/env python3
"""Regenerates every image under assets/ from its source: the docs images (make-docs.py), the
store screenshots (store/make-store.py) and the docs images' light copies (make-light.py). The
SVGs are build output: edit the scripts, run this, and commit both. CI fails if they differ.

    python3 assets/build.py

The app icon has its own generator with extra dependencies (icon/icon.py), and the Android
screenshots are rendered by Gradle (see docs/development.md).
"""
import runpy
from pathlib import Path

here = Path(__file__).parent
for script in ("make-docs.py", "store/make-store.py", "make-light.py"):
    runpy.run_path(str(here / script), run_name="__main__")

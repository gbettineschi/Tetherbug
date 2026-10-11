#!/usr/bin/env python3
"""Write Play's "What's new" text for the version in VERSION, from its section of CHANGELOG.md, to
fastlane/metadata/android/en-US/changelogs/<versionCode>.txt (versionCode as in release.yml).

Play takes plain text up to 500 characters, so headings are dropped and list dashes become bullets.
"""
import re
import sys
from pathlib import Path

PLAY_MAX_CHARS = 500

root = Path(__file__).resolve().parents[2]
version = (root / "VERSION").read_text().strip()
major, minor, patch = (int(n) for n in version.split("-")[0].split("."))
code = major * 10000 + minor * 100 + patch

changelog = (root / "CHANGELOG.md").read_text()
section = re.search(rf"^## {re.escape(version)}\b.*?\n(.*?)(?=^## |\Z)", changelog, re.S | re.M)
if not section:
    sys.exit(f"CHANGELOG.md has no section for {version}")

lines = []
for line in section.group(1).splitlines():
    if line.startswith("#"):
        continue
    line = re.sub(r"^- ", "• ", line)
    line = re.sub(r"\[([^]]*)\]\([^)]*\)", r"\1", line).replace("`", "").replace("**", "")
    if line.strip() or (lines and lines[-1]):
        lines.append(line.rstrip())
text = "\n".join(lines).strip()

if len(text) > PLAY_MAX_CHARS:
    sys.exit(f"{version}'s notes are {len(text)} chars; Play allows {PLAY_MAX_CHARS}. Shorten the change files.")
out = root / f"fastlane/metadata/android/en-US/changelogs/{code}.txt"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(text + "\n")
print(out.relative_to(root))

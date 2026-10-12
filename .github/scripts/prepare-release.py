#!/usr/bin/env python3
"""Finish what knope's PrepareRelease starts, for the versionName it set in android/gradle.properties:
set the matching versionCode there (major*10000 + minor*100 + patch), and write Play's "What's new"
from the version's CHANGELOG.md section to fastlane/metadata/android/en-US/changelogs/<versionCode>.txt.

Play takes plain text up to 500 characters, so headings are dropped and list dashes become bullets.
"""
import re
import sys
from pathlib import Path

PLAY_MAX_CHARS = 500

root = Path(__file__).resolve().parents[2]
props = root / "android/gradle.properties"
version = re.search(r"^versionName=(\S+)", props.read_text(), re.M)[1]
major, minor, patch = (int(n) for n in version.split("-")[0].split("."))
code = major * 10000 + minor * 100 + patch
props.write_text(re.sub(r"^versionCode=\d+$", f"versionCode={code}", props.read_text(), flags=re.M))

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

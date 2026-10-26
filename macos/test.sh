#!/usr/bin/env bash
# Native Mac tests; no Android device, Bluetooth access, or third-party dependencies.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ "${1:-}" = preview ]; then
  preview="$work/Tetherbug Menu Preview.app"
  mkdir -p "$preview/Contents/MacOS"
  cat > "$preview/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>TetherbugMenuPreview</string>
  <key>CFBundleIdentifier</key><string>ie.xav.tetherbug.menu-preview</string>
  <key>CFBundleName</key><string>Tetherbug Menu Preview</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  swiftc -target "$(uname -m)-apple-macos14.0" "$here/Sources/Protocol.swift" \
    "$here/Sources/HotspotControl.swift" "$here/Sources/MenuBar.swift" \
    "$here/Tests/MenuBarPreview.swift" -o "$preview/Contents/MacOS/TetherbugMenuPreview"
  "$preview/Contents/MacOS/TetherbugMenuPreview"
  exit
fi
swiftc -target "$(uname -m)-apple-macos14.0" "$here/Sources/Protocol.swift" "$here/Sources/HotspotControl.swift" \
  "$here/Sources/MenuBar.swift" "$here/Sources/App.swift" \
  "$here/Sources/GeneratedShapes.swift" "$here/Sources/Socket.swift" \
  "$here/Sources/Agent.swift" "$here/Sources/BluetoothRecovery.swift" "$here/Tests/MenuBarTests.swift" "$here/Tests/BluetoothRecoveryTests.swift" \
  "$here/Tests/main.swift" -o "$work/tests"
"$work/tests"

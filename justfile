# Tetherbug's tasks; `just` lists them. The Android and icon recipes bring their own toolchains
# through Nix, so they work from any shell.

default:
    @just --list

# Build the Android debug APK (android/build/outputs/apk/debug/)
android:
    nix develop --command bash -c 'cd android && ./gradlew assembleDebug'

# Build Tetherbug.app into dir (needs Xcode's command line tools)
mac dir="~/Applications":
    macos/build.sh {{ dir }}

# Regenerate every SVG under assets/: the docs images, the store images and the light copies
assets:
    python3 assets/build.py

# Render the Android app's screens on the JVM (assets/store/android/)
android-shots:
    nix develop --command bash -c 'cd android && ./gradlew recordRoborazziDebug'

# Render the store images to the PNGs in fastlane/metadata (on a Mac: they use Apple's fonts)
store-png: assets
    python3 assets/export-png.py

# Everything the store listings show, from the app's screens to the PNGs
store: android-shots store-png

# Regenerate the app icon and everything drawn from it (Android drawables, icon.svg, Mac shapes)
icon:
    "$(nix build --no-link --print-out-paths --impure --expr 'with import <nixpkgs> {}; python3.withPackages (p: [ p.shapely p.svg-path ])')/bin/python3" assets/icon/icon.py

# What CI's Lint checks: generated assets up to date, and commit messages since origin/main
check:
    python3 assets/build.py
    git diff --exit-code -- assets
    python3 .github/scripts/check-commit-messages.py origin/main..HEAD

# Tag and push v<version>, which builds and publishes the release; needs its Play changelog first
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    IFS=. read -r major minor patch <<< "{{ version }}"
    changelog="fastlane/metadata/android/en-US/changelogs/$((major * 10000 + minor * 100 + patch)).txt"
    [ -f "$changelog" ] || { echo "Write $changelog first (the stores show it as What's new)"; exit 1; }
    git tag "v{{ version }}"
    git push origin "v{{ version }}"

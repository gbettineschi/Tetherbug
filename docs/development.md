# Development

## Repository layout

| Path | What |
| --- | --- |
| `android/` | Android app: setup screen and the foreground service (BLE GATT server, hotspot control via Shizuku) |
| `macos/` | Mac app: one binary that is the window, the background agent (`agent`) and the CLI |
| `assets/` | the icon (`icon/`: `icon-source.svg` to edit, `icon.py` generates every shipped icon asset), the docs' images (`images/`) and the scripts that build them |
| `docs/` | [Mac](macos.md) and [SketchyBar](sketchybar.md) guides, this page, the [BLE protocol](protocol.md) |

## Building

Everything builds from the repository root, in the flake's dev shell (JDK 21 and the Android SDK).

```sh
just android      # android/build/outputs/apk/debug/
just mac          # Tetherbug.app in ~/Applications (needs Xcode command line tools)
```

Every task has a recipe in the `justfile`; `just` lists them, and `nix develop` provides `just`.

`macos/build.sh` also renders the Mac app icon from the buddy outline, so no
raster assets live in the repo. After changing the icon, regenerate the
Android drawables, `assets/icon/icon.svg` and the Mac's shape data:

```sh
just icon
```

CI builds the Android and Mac apps on every push.

## Releasing

Releases use [knope](https://knope.tech) change files. When a change should show up in the
release notes, add one with `just change`: it asks for the kind of change (`major` breaks
something, `minor` adds something, `patch` fixes something) and a one-line summary, and writes a
note to `.changeset/`. Commit it with the change.

Every push to main then updates a "chore: prepare release" pull request, which bumps `VERSION`,
moves the notes into `CHANGELOG.md` and writes Play's "What's new" text. Merging it publishes:
the GitHub release with the signed APK and the Mac app, the Homebrew cask, and Play's internal
testing track. To choose the version yourself (such as 1.0.0), run the Prepare release workflow
by hand with a version.

## Documentation images

Every image under `assets/` is generated, never edited by hand: `assets/make-docs.py` draws the
docs images and `assets/store/make-store.py` the store screenshots, both from the shared parts in
`assets/draw.py` (the laptop, phone, the app's switch, macOS's Wi-Fi and Personal Hotspot marks).
They're drawn for dark mode; `assets/make-light.py` writes the `-light.svg` copies the README shows
to GitHub's light theme. After changing any of them, rebuild and commit the scripts and the SVGs
together; CI fails if the two disagree:

```bash
just assets
```

The store listings (`fastlane/metadata/`: title, descriptions, release notes and images, which
F-Droid and IzzyOnDroid read from here and releases upload to Play) take PNGs. After changing a
store image, render them on a Mac, since the images use Apple's fonts; this also renders the
README's hero image:

```bash
just store-png
```

The Android store screenshots in `assets/store/android/` are rendered on the JVM (Roborazzi and
Robolectric, no phone needed) from the placeholder data in `android/src/test/.../ScreenshotTest.kt`.
After changing the setup screen, regenerate them (`just store` also re-renders the PNGs):

```bash
just android-shots
```

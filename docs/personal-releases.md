# Personal release channel

Both apps are patched. Install updates from [gbettineschi/Tetherbug](https://github.com/gbettineschi/Tetherbug/releases), not upstream. The fork retains the original package and bundle ID, `ie.xav.tetherbug`.

## Android and Obtainium

Add `https://github.com/gbettineschi/Tetherbug` in Obtainium. Releases contain one APK; no asset filter is required. Release tags and Android version names match (`v0.1.6` / `0.1.6`). After importing an already installed personal build, Obtainium may initially offer the newer release. Install it as an update, without uninstalling or clearing data.

The personal signing certificate SHA-256 is:

```text
66e308329c2e4813943e4cc1c9672831fb8897e3d65ac5d1ef252a90ce7a9be6
```

This matches the retained `0.1.1-btfix.4` APK. Future updates must keep that certificate and increase Android's `versionCode`. The release builder checks the certificate and package/version. Keep a private backup of the original keystore and its password; losing them means future APKs cannot update this installation in place. They are not uploaded to GitHub, including Actions secrets.

Official upstream, F-Droid or other independently signed APKs cannot update this installation directly. Replacing it with another signing key requires uninstalling and resets app settings and permissions. A fork release preserves the patches; official changes should first be merged into the fork.

## macOS

The release ZIP contains a universal Apple Silicon/Intel app. Quit Tetherbug, replace the existing app at the same location, and reopen it. Preserve its Application Support and preferences files. The bundle ID is unchanged; the ad-hoc signing identity is not stable across builds, so Bluetooth permission can require renewed approval. Downloads are not notarized: allow the app in System Settings → Privacy & Security if macOS blocks it.

Homebrew can track a custom cask from this repository. An embedded Sparkle updater would require a separate implementation; it is not included. The Latest app only covers supported update mechanisms such as Sparkle and the App Store, so it cannot discover these plain ZIP releases automatically.

## Making the next release

1. Review and merge desired upstream commits. Keep the personal Android changes and package ID. Do not replace the fork branch with upstream's branch.
2. Update `android/gradle.properties`: increase both numeric `versionName` and `versionCode`. Start above versionCode **105**, used by the old personal build. Add `releases/<version>.md` with notes for both platforms.
3. Commit the release sources and push them to this fork's `main`.
4. On a Mac with Command Line Tools, JDK 21 and the Android SDK, set `JAVA_HOME`, `ANDROID_HOME` and optionally `GRADLE_USER_HOME`. Select a compatible SDK with `SDKROOT` if required by the installed Swift tools.
5. Run `python3 scripts/release.py --publish`. Omit `--publish` to build without uploading. It runs the focused Android regression suites and all Mac tests, builds the signed APK and universal app, verifies the Android certificate and identity, and publishes the APK, ZIP, SHA-256 checksums and source manifest. It never installs either app or changes device settings.

The private signing configuration is read from `~/.local/share/tetherbug/android-signing/signing.json`, or `TETHER_SIGNING_CONFIG`. It contains `keystore` (path to the retained PKCS12/JKS file), `alias`, and `password`. A relative key path is resolved next to the JSON. Keep both files private and backed up; never commit them. No password is printed or included in command-line arguments.

GitHub Actions verifies builds and tests only. Release signing stays local, and the upstream Play Store/tap publishing jobs are deliberately absent.

Before publishing, the builder requires a clean source tree and verifies that its commit is already the fork's `main`. Release tags are immutable in this workflow: publish a new version rather than replacing an existing asset. The MIT license is included in both app bundles.

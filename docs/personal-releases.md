# Personal release channel

Both apps are patched. Install updates from [gbettineschi/Tetherbug](https://github.com/gbettineschi/Tetherbug/releases), not upstream. The fork retains the original package and bundle ID, `ie.xav.tetherbug`.

## Android and Obtainium

On the phone, with Obtainium installed, [open the prepared import](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22ie.xav.tetherbug%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Fgbettineschi%2FTetherbug%22%2C%22author%22%3A%22gbettineschi%22%2C%22name%22%3A%22Tetherbug%20Personal%22%7D) and confirm adding **Tetherbug Personal**. This imports the app’s package ID, fork URL and name; it does not install an APK silently. The readable source is [updates/obtainium.json](../updates/obtainium.json). The defaults use GitHub release APKs; no custom filters, login or token are needed for this single public app.

Add `https://github.com/gbettineschi/Tetherbug` in Obtainium. Releases contain one APK; no asset filter is required. Release tags and Android version names match (`v0.1.6` / `0.1.6`). After importing an already installed personal build, Obtainium may initially offer the newer release. Install it as an update, without uninstalling or clearing data.

The personal signing certificate SHA-256 is:

```text
66e308329c2e4813943e4cc1c9672831fb8897e3d65ac5d1ef252a90ce7a9be6
```

This matches the retained `0.1.1-btfix.4` APK. Future updates must keep that certificate and increase Android's `versionCode`. The release builder checks the certificate and package/version. Keep a private backup of the original keystore and its password; losing them means future APKs cannot update this installation in place. They are not uploaded to GitHub, including Actions secrets.

Official upstream, F-Droid or other independently signed APKs cannot update this installation directly. Replacing it with another signing key requires uninstalling and resets app settings and permissions. A fork release preserves the patches; official changes should first be merged into the fork.

## macOS

The release ZIP contains a universal Apple Silicon/Intel app. Quit Tetherbug, replace the existing app at the same location, and reopen it. Preserve its Application Support and preferences files. The bundle ID is unchanged; the ad-hoc signing identity is not stable across builds, so Bluetooth permission can require renewed approval. Downloads are not notarized: allow the app in System Settings → Privacy & Security if macOS blocks it.

Homebrew can track the included `Casks/tetherbug-personal.rb` from this repository. Set it up with `brew tap gbettineschi/tetherbug https://github.com/gbettineschi/Tetherbug`, then install `gbettineschi/tetherbug/tetherbug-personal`. Later, `brew update` followed by `brew upgrade --cask gbettineschi/tetherbug/tetherbug-personal` installs the fork’s new Mac releases. This does not create a background update schedule. For a first move from another app location, turn off **Launch at login** in the old copy and quit it. Install/open the Homebrew copy, then enable **Launch at login** there. Keep preferences and app data intact; this changes the helper registration to the new bundle location. Subsequent Homebrew upgrades retain that location. An embedded Sparkle updater would require a separate implementation; it is not included. The Latest app only covers supported update mechanisms such as Sparkle and the App Store, so it cannot discover these plain ZIP releases automatically.

On the tested Mac, the first registration of the downloaded ad-hoc build was marked enabled but macOS rejected its helper with a launch-constraint error. After approving **Open Anyway**, switching **Launch at login** off and back on in the new app rebuilt the registration. The resulting launchd-owned helper was verified running after the settings window closed. This is a verified first-install recovery, not a promise that arbitrary future signature changes need no approval. The personal release build has no Developer ID/notarization configured.

## Making the next release

1. Review and merge desired upstream commits. Keep the personal Android changes and package ID. Do not replace the fork branch with upstream's branch.
2. Update `android/gradle.properties`: increase both numeric `versionName` and `versionCode`. Start above versionCode **105**, used by the old personal build. Add `releases/<version>.md` with notes for both platforms.
3. Commit the release sources and push them to this fork's `main`.
4. On a Mac with Command Line Tools, JDK 21 and the Android SDK, set `JAVA_HOME`, `ANDROID_HOME` and optionally `GRADLE_USER_HOME`. Select a compatible SDK with `SDKROOT` if required by the installed Swift tools.
5. Run `python3 scripts/release.py --publish`. Omit `--publish` to build without uploading. It runs the focused Android regression suites and all Mac tests, builds the signed APK and universal app, verifies the Android certificate and identity, and publishes the APK, ZIP, SHA-256 checksums and source manifest. It never installs either app or changes device settings.

6. After publishing, update `Casks/tetherbug-personal.rb` with that version and the Mac ZIP’s SHA-256 from `SHA256SUMS.txt`; commit and push this metadata change to `main`. This keeps the Homebrew channel on the new release. Do not change the already published source tag.

The private signing configuration is read from `~/.local/share/tetherbug/android-signing/signing.json`, or `TETHER_SIGNING_CONFIG`. It contains `keystore` (path to the retained PKCS12/JKS file), `alias`, and `password`. A relative key path is resolved next to the JSON. Keep both files private and backed up; never commit them. No password is printed or included in command-line arguments.

GitHub Actions verifies builds and tests only. Release signing stays local, and the upstream Play Store/tap publishing jobs are deliberately absent.

Before publishing, the builder requires a clean source tree and verifies that its commit is already the fork's `main`. Release tags are immutable in this workflow: publish a new version rather than replacing an existing asset. The MIT license is included in both app bundles.

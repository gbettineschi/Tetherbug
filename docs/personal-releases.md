# Personal release channel

Both apps are patched. Install updates from [gbettineschi/Tetherbug](https://github.com/gbettineschi/Tetherbug/releases), not upstream. The fork retains the original package and bundle ID, `ie.xav.tetherbug`.

## Android and Obtainium

On the phone, with Obtainium installed, [open the prepared import](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22ie.xav.tetherbug%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Fgbettineschi%2FTetherbug%22%2C%22author%22%3A%22gbettineschi%22%2C%22name%22%3A%22Tetherbug%20Personal%22%7D) and confirm adding **Tetherbug Personal**. This imports the app’s package ID, fork URL and name; it does not install an APK silently. The readable source is [updates/obtainium.json](../updates/obtainium.json). The defaults use GitHub release APKs; no custom filters, login or token are needed for this single public app.

Add `https://github.com/gbettineschi/Tetherbug` in Obtainium. Releases contain one APK; no asset filter is required. Release tags and Android version names match (`v0.1.7` / `0.1.7`). After importing an already installed personal build, Obtainium may initially offer the newer release. Install it as an update, without uninstalling or clearing data.

The personal signing certificate SHA-256 is:

```text
66e308329c2e4813943e4cc1c9672831fb8897e3d65ac5d1ef252a90ce7a9be6
```

This matches the retained `0.1.1-btfix.4` APK. Future updates must keep that certificate and increase Android's `versionCode`. The release builder checks the certificate and package/version. Keep a private backup of the original keystore and its password; losing them means future APKs cannot update this installation in place. The retained key is backed up locally and stored in encrypted GitHub Actions environment secrets for automatic releases; it is never committed or included in downloads.

Official upstream, F-Droid or other independently signed APKs cannot update this installation directly. Replacing it with another signing key requires uninstalling and resets app settings and permissions. A fork release preserves the patches; official changes should first be merged into the fork.

## macOS

The release ZIP contains a universal Apple Silicon/Intel app. Quit Tetherbug, replace the existing app at the same location, and reopen it. Preserve its Application Support and preferences files. The bundle ID is unchanged; the ad-hoc signing identity is not stable across builds, so Bluetooth permission can require renewed approval. Downloads are not notarized: allow the app in System Settings → Privacy & Security if macOS blocks it.

Homebrew tracks `Casks/tetherbug-personal.rb` in the shared [public tap](https://github.com/gbettineschi/homebrew-tap). Set it up with `brew tap gbettineschi/tap`, then install `gbettineschi/tap/tetherbug-personal`. Later, `brew update` followed by `brew upgrade --cask gbettineschi/tap/tetherbug-personal` installs the fork’s new Mac releases. This does not create a background update schedule. For a first move from another app location, turn off **Launch at login** in the old copy and quit it. Install/open the Homebrew copy, then enable **Launch at login** there. Keep preferences and app data intact; this changes the helper registration to the new bundle location. Subsequent Homebrew upgrades retain that location. An embedded Sparkle updater would require a separate implementation; it is not included. The Latest app only covers supported update mechanisms such as Sparkle and the App Store, so it cannot discover these plain ZIP releases automatically.

On the tested Mac, the first registration of the downloaded ad-hoc build was marked enabled but macOS rejected its helper with a launch-constraint error. After approving **Open Anyway**, switching **Launch at login** off and back on in the new app rebuilt the registration. The resulting launchd-owned helper was verified running after the settings window closed. This is a verified first-install recovery, not a promise that arbitrary future signature changes need no approval. The personal release build has no Developer ID/notarization configured.

## Making the next release

1. Review and merge wanted upstream commits. Preserve the personal changes, Android package ID and signing identity.
2. Update `android/gradle.properties`: increase numeric `versionName` and `versionCode` above the preceding release. Add `releases/<version>.md` with notes for both platforms.
3. Commit and push the reviewed source to this fork's `main`. Push a matching `vX.Y.Z` tag, or run `python3 scripts/release.py --publish` from that clean commit to push the tag for you.
4. **Release personal apps** tests the focused Android regressions and all Mac tests, builds/signs both apps, checks the retained Android certificate and package/version, and publishes the APK, universal Mac ZIP, checksums and source manifest.
5. Its dependent tap job updates the shared Homebrew recipe automatically. Obtainium discovers the Android APK from the same GitHub release. There is exactly one APK per release, so no APK filter is needed.

The one automatic publisher owns release creation. The local `--publish` command requests that workflow; it no longer builds a second competing release. The automatic job checks that its tag points to the exact source commit on `main`. Published downloads are immutable: use a new version instead of replacing assets. To retry only the tap, run **Update Homebrew tap** with the existing tag.

## Signing and local verification

The Android key, password and alias are encrypted secrets in the **android-release** Actions environment. That environment permits version tags and `main` manual verification, without pull-request access. The key is restored to a private temporary file on a disposable runner and removed afterward. This is a public repository; secret values are not public. A person able to alter trusted release workflows could misuse signing access, so keep repository write access controlled.

For a non-publishing CI check, run **Release personal apps** manually on `main`. It builds and verifies both packages without uploading installers or creating a release or tap update. Routine CI also tests/builds without keeping installer downloads. Tagged releases publish installers directly to GitHub Releases, with no duplicate Actions artifact.

Local build-only packaging is still available with `python3 scripts/release.py`. It reads `~/.local/share/tetherbug/android-signing/signing.json`, or `TETHER_SIGNING_CONFIG`, containing `keystore` (path), `alias`, and `password`. Relative key paths are resolved next to that JSON. Use Command Line Tools, JDK21 and Android SDK37; set `JAVA_HOME` and `ANDROID_HOME` as needed. Keep the retained key and config private and backed up. No password is printed or passed as a command-line argument. Builds do not install apps or change device settings.

The Mac build is ad-hoc signed and not notarized; no Apple signing key is uploaded. The MIT licence is included in both bundles. GitHub's standard hosted runner execution is free for this public repository.

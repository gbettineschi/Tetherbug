# Tetherbug Personal

A personal fork of [xav-ie/Tetherbug](https://github.com/xav-ie/Tetherbug) with patches for **Android and macOS**. It controls an Android hotspot from a native Mac menu over encrypted Bluetooth LE, without root or a shared Wi-Fi network. Android hotspot control requires Shizuku.

## Downloads and updates

Download the APK and universal Mac app from **[this fork’s releases](https://github.com/gbettineschi/Tetherbug/releases/latest)**. Follow this fork on both platforms to keep the patches; the upstream project’s releases do not contain them.

- **Android / Obtainium:** add `https://github.com/gbettineschi/Tetherbug`. Each release contains exactly one APK. It uses the same application ID and personal signing certificate as the previously installed `0.1.1-btfix.4`, so it updates in place. Do not uninstall first. Official APKs have a different signature and cannot update this personal installation.
- **macOS:** download `Tetherbug-v<version>.zip`, quit Tetherbug, and replace the existing app. The bundle ID is unchanged, so preferences stay in place. These builds are ad-hoc signed and not notarized: macOS may require Open Anyway and renewed Bluetooth approval. There is no embedded automatic updater.
- Official changes can be reviewed and merged into this fork before making a new personal release. Updates are not merged automatically.

See [release and signing instructions](docs/personal-releases.md), [Mac setup](docs/macos.md), and the [BLE protocol](docs/protocol.md).

## Changes in this fork

**Mac:** native menu with a blue Mobile Hotspot switch, actual phone name, Automatic mode and inline pause status; stable menu-bar icon during requests; improved helper startup, Bluetooth discovery/recovery and native settings. Closing settings keeps the menu bar; Quit exits everything. Turning the hotspot off while Automatic mode is enabled pauses automatic activation for 15 minutes; a manual On cancels the pause. A Mac deliberately kept awake with its lid closed retains normal automatic behaviour.

**Android:** Bluetooth server recovery after radio changes; preserved bonded status subscriptions across app updates; Shizuku readiness notifications; optional app notifications; the phone’s native hotspot timeout is left untouched. Android can still display its own foreground-service indicator. Background startup depends on Android/Samsung and Shizuku being available; it is not guaranteed to be instantaneous.

## Setup

1. Install the personal Android APK, allow Bluetooth access and Shizuku, and start its service. Notifications are optional. Android 13+ is required.
2. Pair the phone and Mac in their Bluetooth settings.
3. Open the Mac app, allow Bluetooth access, and enable Run in the background. macOS 14+ is required.
4. Use the menu-bar Mobile Hotspot switch, or enable Automatic mode to request the hotspot when Mac Wi-Fi stays disconnected.

## Samsung / Personal Hotspot icon limitation

The tested Galaxy S23 firmware accepts the Apple marker in Android’s hotspot configuration but does not transmit it in captured beacons. The linked-ring icon in macOS Wi-Fi therefore remains unavailable on that device. This fork **does not fix that firmware limitation** and does not implement Apple Continuity’s off-state discovery. The native Tetherbug menu and Bluetooth hotspot control work independently of that icon.

## License and attribution

[MIT](LICENSE), retaining Xavier Ruiz’s original copyright and license. This is an independent personal fork, not an official release. Device logs, credentials, signing keys and personal diagnostic notes are not included.

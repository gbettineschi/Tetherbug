# Privacy policy

Effective October 11, 2026. This covers the Tetherbug apps for Android and macOS.

Tetherbug collects no data. Neither app has an account, analytics, ads or crash reporting, and the
Android app has no internet access at all. Nothing is sent to the developer or to anyone else.

## What stays between your devices

Tetherbug's job is to let your Mac turn your phone's hotspot on. To do that, the phone and the Mac
talk directly over Bluetooth, and only once you've paired them. The link is encrypted, and the
phone answers no device it isn't paired with. Over it, the phone shares:

- whether the hotspot is on, and its network name and Wi-Fi channel, so your Mac can find it quickly
- the hotspot's password, so the Mac can show it to you
- the phone's battery level and signal strength, which the Mac shows

The Mac sends back only requests to turn the hotspot on or off.

## What each app keeps

- **Android:** your Tetherbug settings, such as the hotspot timeout, stay on the phone.
- **macOS:** your Tetherbug settings stay on the Mac. Tetherbug keeps the hotspot's password only
  in memory while it runs. When you join the hotspot, macOS may save it, as it does for any Wi-Fi
  network.

## Permissions

- **Bluetooth (Android and macOS):** to talk to your paired device.
- **Wi-Fi state (Android):** to read the hotspot's state and settings.
- **Notifications (Android):** for the notification Android requires while Tetherbug runs in the
  background.
- **Run at startup (Android):** so Tetherbug is ready after the phone restarts.
- **Shizuku (Android):** to switch the hotspot on and off without root.

## Changes and contact

Changes to this policy are published here, with a new effective date. Questions go to
[Tetherbug's issues on GitHub](https://github.com/xav-ie/Tetherbug/issues).

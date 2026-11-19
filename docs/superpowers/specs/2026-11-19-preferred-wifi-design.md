# Preferred Wi-Fi handover

Approved scope: the user accepted automatic handover to a chosen Wi-Fi list, then hotspot shutoff, and explicitly requires all changes to be Mac-only.

Add an optional “Preferred Wi-Fi” section in Mac Settings, with a switch, a list of exact network names, Add Current Network, and removal. Explain that networks must already be saved in macOS. Request Location access only from an explicit Settings button; never request GPS updates. Default disabled and empty, preserving existing behaviour.

While fully awake, automatic mode active and not paused, and the paired phone reports a controllable running hotspot, scan at most once per minute if the Mac is using that hotspot or has lost its Wi-Fi. Prefer listed, visible, saved networks in list order. Leave an unrelated working Wi-Fi alone. Exclude the phone’s hotspot from the preferred candidates.

Ask macOS to join using its saved credentials, without collecting or storing passwords in Tetherbug. Wait for the exact selected SSID and a connected Wi-Fi path to remain stable for three seconds, then check internet access over Wi-Fi using an authenticated TLS connection to Apple’s connectivity endpoint. Only then send hotspot Off over the existing Bluetooth protocol. A network merely being visible or having a local IP is insufficient. A captive portal, failed join, vanished network, or failed internet check must never turn the hotspot off. Back off failed candidates for five minutes and restore the previous hotspot connection after a failed attempted handover when appropriate. Never override an intervening user-selected connection.

If macOS itself joins a listed network, perform the same verification and hotspot shutoff. Existing five-minute hotspot shutdown cooldowns remain unchanged. Disabled or paused automatic mode blocks this feature too.

A manually/native joined network is observed, not owned by Tetherbug: if its internet check fails, leave it connected so the user can complete captive-portal login. Restore the hotspot only to undo an agent-initiated failed handover. A manually selected unrelated network cancels any outstanding join or restoration. Bind the internet probe to the exact Wi-Fi adapter whose SSID was checked, not just the Wi-Fi interface type. Avoid Wi-Fi identity polling while automatic mode is paused or off.

Before sleep/DarkWake, cancel queued joins, connection probes, and processing of scan results. Check awake ownership again at every asynchronous boundary. In-progress OS scans cannot be recalled, but their results cannot produce follow-up work. No Android changes, no new phone permissions, no wake assertions, no Keepresso integration.

Build and test both Mac architectures, install in place at `/Applications/Tetherbug.app`, and keep any rollback bundle compressed. Ship no duplicate app bundles. A live network-switch test requires actual selected networks; report its absence honestly. Publishing a release remains separate from implementing and installing this feature.

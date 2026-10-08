# BLE protocol

One primary service. Every characteristic requires an encrypted, bonded link,
so only a paired Mac can use it; the advertisement carries nothing but the
service UUID.

| UUID | Name | Properties | Payload |
| --- | --- | --- | --- |
| `1581bac4-33fe-43a8-b97f-5dd7a01f48c9` | service | | |
| `90766fca-8a24-43ae-8501-3dcef06a8479` | status | read, notify | `version u8` (3), `hotspot u8` (0 off, 1 starting, 2 on, 3 failed), `battery u8` (%), `signal u8` (cell, 0–4), `flags u8` (bit 0: hotspot controllable, i.e. Shizuku ready), `frequency u16` (little-endian MHz of the running hotspot, 0 unknown), `ssid` (UTF-8, rest). Version 2 had no `frequency`; version 1 had no `flags` either. |
| `e036426f-6317-487d-8777-e6f6d91f8a4d` | command | write | `0x01` enable, `0x02` disable |
| `355534b0-7222-480b-aa18-02a6c30feea2` | credentials | read | hotspot passphrase (UTF-8) |

The phone notifies status whenever the hotspot state changes; a command that
asks for the state the hotspot is already in is a no-op. The Mac agent reads
the passphrase on connect and whenever the hotspot comes on, and hands it out
only on an explicit request, never in its status stream.

With the frequency known, the Mac scans just that channel when the hotspot
comes on, so it lands in macOS's scan cache (and the Wi-Fi menu) within about a
second instead of waiting on a full scan.

See the [README](../README.md#how-macos-recognises-a-personal-hotspot) for how the hotspot is made to look like an iPhone's.

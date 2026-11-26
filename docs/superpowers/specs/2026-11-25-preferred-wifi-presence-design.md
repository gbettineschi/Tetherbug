# Preferred Wi-Fi presence instead of network switching

The user chose a simpler replacement: detect a visible preferred network and turn the phone hotspot off. Off is part of Automatic Mode; disabling or pausing that mode prevents it. macOS owns all association, saved login and auto-join decisions. Visibility is not proof of internet service or successful auto-join.

## Approach

Replace the bidirectional handover/credential/probe subsystem with one read-only presence scanner and a small policy. The rejected approach was continuing CoreWLAN association and Keychain recovery; it has failed actual-device trials and is unnecessary for this new behavior. Waiting for an already-associated preferred network would avoid a possible gap but would not satisfy the user's presence-based instruction.

Keep the preferred list and existing “Prefer hotspot for…” timer. That timer now suppresses preferred-network Off only; it never connects to a network or diagnoses internet. Remove the separate return-to-preferred toggle: Automatic Mode is the single master switch, with the existing timed pauses. Keep the existing five-minute courtesy after a native/manual network change.

## Rules

- Scan at most once per minute across list/mode changes, only in FullWake with existing Location permission, valid saved preferred networks and an operational phone with a known hotspot identity. Never request permission from the worker. Unknown hotspot identity withholds presence Off while allowing ordinary On.
- While the phone hotspot is On, a fresh successful scan showing a preferred saved SSID/security permits Off, subject to Automatic Mode, its pauses, the hotspot-preference timer and courtesy delay. Exclude the phone hotspot itself.
- While the Mac is disconnected and the hotspot is Off, check presence before automatic On. A visible preferred network suppresses On; refresh once a minute so leaving its range can re-enable ordinary activation. This prevents an On/Off loop.
- Unknown presence waits for a bounded first scan. A failed/timed-out scan never sends Off and allows ordinary disconnected-only On; errors are not evidence that a preferred network is absent. Observation freshness is 90 seconds, scan budget 15 seconds, retry spacing 60 seconds. Do not queue another scan while the OS call is still running.
- Recheck eligibility and configuration when asynchronous results arrive. Sleep, Automatic Mode changes, timer changes and list changes invalidate pending work. A blocking scan cannot be forcibly stopped, but no stale callback may control the phone.
- Network-change courtesy restricts Off only. It must not bypass the pre-On presence check. Sample the physical link and native SSID in the decision snapshot, including asynchronous completion, before applying that courtesy. Automatic On requires the complete Bluetooth metadata/subscription handshake.
- Preserve ordinary manual hotspot controls, the five-minute nearby phone-shutdown pause, Bluetooth recovery, stable signing, one installed app, login registration and all Android behavior.

## Delivery

Implement inline under the user's standing autonomous-implementation instruction, with meaningful policy tests and one independent final review. Build and install a same-signer Mac-only trial in place. Real verification is hotspot On/Off while home Wi-Fi remains associated; no Wi-Fi switch is attempted. Do not publish or merge before that behavior is verified.

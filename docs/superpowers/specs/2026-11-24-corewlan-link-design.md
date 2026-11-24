# Public Wi-Fi association and disconnected-only activation

User-authorized scope, including the clarification on 24 November: retain automatic return to preferred Wi-Fi; enable the phone hotspot automatically only when the Mac is disconnected from Wi-Fi. A connected Wi-Fi with broken internet is the user's decision to leave. Proceed autonomously under the standing implementation authorization.

## Approach

Replace the private CoreWiFi saved-profile association backend with public CoreWLAN scanning and its personal/enterprise association methods. Read credentials only for the exact saved target through public CoreWLAN Keychain functions; never log or persist credentials, edit profiles, or weaken certificate validation. Retain ownership until a blocking association actually returns, including across cancellation and sleep. Suppress stale completions and do not start new work in DarkWake.

Use SystemConfiguration's Wi-Fi physical-link state to decide whether the Mac is disconnected. NWPath readiness remains useful for DHCP/verification, but must not be used as evidence that an associated network should be replaced. Unknown link state and Wi-Fi powered off fail closed. Recheck association immediately before automatic On commands.

Keep preferred-network order, minute scans, five-minute failure backoff, stable-connection checks and Wi-Fi-bound HTTPS verification. Keep the hotspot available until a preferred network passes verification. Distinguish association failures from internet-check failures in the status message.

## Alternatives

- Keep private CoreWiFi: rejected; the real installed app is denied its restricted entitlement.
- Use the legacy networksetup join: rejected; earlier campus tests associated without reliably starting 802.1X.
- Remove preferred Wi-Fi handover: rejected by the user's explicit clarification.

## Constraints and verification

Mac only; no Android update. Preserve settings, phone pairing, retained signing identity, launch at login and the single installed /Applications/Tetherbug.app. Tests must not change a real network or prompt for credentials. Verify disconnected, connected-without-internet, powered-off and unknown-link cases; enterprise/personal routing; cancelled and in-flight association ownership. Build and verify with the retained signer before installing in place. A real campus handover is separate evidence and must not be claimed from unit tests.

## Temporary hotspot preference (additional user instructions)

Add a native “Prefer hotspot for…” submenu, including 6 hours and an explicit stop action. The preference has its own persisted deadline, independent of Automatic Mode suspension; choices replace rather than add time. Only menu cancellation or expiry clears it, per the user's explicit answer: a return to preferred Wi-Fi must not cancel it.

During that preference, skip return-to-preferred attempts. When the paired phone hotspot is already on, it becomes the target network, even if the present Wi-Fi works. Do not turn it on just because the preference starts on healthy Wi-Fi. Only in this mode, detect unusable associated Wi-Fi using two interface-bound failed internet probes before requesting hotspot On. Normal mode never enables hotspot for poor internet on an associated Wi-Fi.

Use the same association/settling/verification/restoration state machine in both directions. After a network change not owned by Tetherbug, delay application-initiated switching for five minutes in either direction; a subsequent external change replaces the deadline with five minutes from that change. A failed candidate also gets five-minute backoff; scans remain at most once per minute. A known disconnected link can still use the existing five-second hotspot activation delay. The OS may independently auto-join; this policy only governs Tetherbug. Sleep cancels probes and invalidates callbacks. Keep one network operation owner and never overlap scans/joins/probes.

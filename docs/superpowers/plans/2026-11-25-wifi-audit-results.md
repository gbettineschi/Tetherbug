# Wi-Fi audit and scan-only evidence — 25 November 2026

## Current implementation

Installed `0.1.13-wifi.5`, source `02a9bcf56721573141dba6e6fa7b5a8b28f51fd1`, with the retained signing certificate. Public CoreWLAN scans and associates. SystemConfiguration supplies physical link state. Enterprise association uses `associate(toEnterpriseNetwork:identity:nil,username:nil,password:nil)`; personal Wi-Fi retains its scoped public credential helper. The public declaration accepts nullable enterprise credentials but does not promise equivalence to the Wi-Fi menu's saved-profile selection.

## Confirmed defects and corrections

- Discovery discarded its `CWNetwork` objects, followed immediately by another directed scan before association. Preserve a short-lived snapshot, scoped to interface and awake generation, and reuse its actual objects. The adapter rechecks freshness after queueing.
- Scan errors were either swallowed or reported under the generic association label. Keep only sanitized stage/domain/code, separating discovery, directed scan, credential lookup and association. Never retain error descriptions/userInfo.
- Logical timeouts could lose an outstanding join's intent while still on its original network. Retain ownership until the blocking OS call returns, then reconcile the observed link.
- A late restoration could appear to be an external choice. Retain its target through the first post-completion observation. Restoration retries also honor a newer external-choice courtesy period.
- A cache-seed scan queued while switching was disabled could run after settings changed. Recheck settings at execution; preserve its existing single bounded retry.

These are confirmed application defects. They do not retroactively identify which OS call produced the earlier EBUSY.

## Isolated hardware observation

The explicit diagnostic holds the existing worker lifetime lock while the app/worker is stopped. It invokes no association, disassociation, credential lookup, configuration write or power change. It reproduces the **old** discovery-then-directed-scan sequence once, to observe each operation separately.

Initial short-lived invocations stopped before scanning because authorization was read before the initial Core Location callback. The final probe waits for that callback, retains the manager, and never requests permission or location updates. No new Location grant was needed for the successful execution below.

Observed report:

| Stage | Duration | Identifiable SSIDs | Saved target `epfl` seen | Error |
|---|---:|---:|---|---|
| Discovery | 4.936 s | 49 | Yes | None |
| Immediate directed scan | 0.017 s | 0 | No | None |

The SSID read before and after was equal. This is endpoint evidence, not a continuous link trace. A Wi-Fi-bound HTTPS check returned HTTP 200 afterward. No connection attempt to EPFL occurred.

The second call can therefore lose a target found by the first. The production snapshot reuse avoids this redundant step. This single trial does not establish why macOS omitted the target from the directed result, whether that omission caused a previous failure, or whether enterprise saved authentication works.

The earlier `NSPOSIXErrorDomain` code 16 was **not reproduced**. Its old catch boundary covered both directed scan and association. EBUSY is an OS state/resource error, not evidence of an incorrect password or proof of QuickDrop interference. Apple's published EAPOL controller can also return EBUSY when an existing 802.1X client is in a transitional state; this is a concrete possible source, not an attribution of our historical error.

## Verification and remaining boundary

- Native suite: 140 tests, 0 failures, including red/green late-completion and courtesy regressions.
- Universal candidate and protected signing passed in [trial run 45594433068](https://github.com/gbettineschi/Tetherbug/actions/runs/45594433068).
- Retained signer, pairing/Bluetooth, native login enabled, no legacy login job or pending approval verified after installation.
- One `/Applications/Tetherbug.app`; temporary previous bundles removed, compressed rollback retained.
- Automatic preferred-network return and timed hotspot preference remain off. General automatic activation remains enabled. Phone hotspot was off at the final check.
- Temporary signing branch policy removed; only the original `v*` tag rule remains. No Android update, release, tap update or merge.
- A controlled actual association test is still required before claiming reliable campus handover or native saved-profile reuse. Keep PR #2 as a draft.

Evidence files: `/tmp/tetherbug-scan-only-ready-2026-11-25/diagnostic.json`, `/tmp/tetherbug-wifi5-final-test.log`. Signing receipt is in `build/trial-signed-corewlan-5/signing.json`.

References: [Apple enterprise association](https://developer.apple.com/documentation/corewlan/cwinterface/associate(toenterprisenetwork:identity:username:password:)), [directed scan contract](https://developer.apple.com/documentation/corewlan/cwinterface/scanfornetworks(withssid:)), [Apple EAPOL transitional EBUSY](https://github.com/apple-oss-distributions/eap8021x/blob/6f181a4221f6a0a8bf9559894818cb4f0f369b25/EAPOLController.bproj/controller.c#L1406-L1415).

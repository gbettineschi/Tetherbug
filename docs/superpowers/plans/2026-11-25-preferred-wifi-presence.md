# Preferred Wi-Fi Presence Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, task by task, then one fresh independent review.

**Goal:** Turn the phone hotspot off on preferred Wi-Fi presence under Automatic Mode, leaving network selection to macOS.

**Architecture:** One cancellable read-only scanner plus one main-queue presence policy. Remove association, Keychain, restoration and HTTP fallback code. Preserve list, timer and ordinary hotspot behavior.

**Tech Stack:** Swift, CoreWLAN scanning, existing power guards, native SwiftUI settings and retained signer.

**Spec:** `docs/superpowers/specs/2026-11-25-preferred-wifi-presence-design.md`

## Global Constraints

- Mac only; one installed app, same signer, no network association/disassociation, credential lookup, trust change or Android modification.
- Automatic Mode is the master switch; its pauses and existing five-minute network courtesy apply. “Prefer hotspot for…” suppresses presence Off.
- 60-second scan spacing, 90-second observation lifetime, 15-second logical scan budget; actual OS scan ownership survives cancellation.
- Unknown/failed observations never turn the phone off. A bounded failed scan allows ordinary disconnected-only On.

## Review Focus

- Stale results after sleep, disable, pause or list/timer changes must not send Off.
- Preferred presence must not produce a repeated On/Off loop when macOS cannot join.
- Scan errors, timeout and a still-running OS call must not block hotspot use indefinitely or queue radio work.
- Same-name open networks, canonically equivalent raw SSIDs and the phone hotspot must not qualify accidentally.
- Existing Bluetooth metadata, login, pause and menu behavior must remain covered after obsolete handover tests are removed.

## Task 1: Presence policy

- [x] Add failing policy tests for visible/absent networks, Automatic Mode/override gates, stale completions, presence suppression, freshness, timeout, retry bounds and non-overlapping scans.
- [x] Implement `PreferredWifiPresence` and `WifiPresenceScanner` with context-driven eligibility and a read-only result interface.
- [x] Run the complete native suite and commit the policy.

## Task 2: Native scanner and app integration

- [x] Replace the native handover service with a saved-SSID/security-matching scanner; retain actual pending ownership through cancel.
- [x] Integrate the policy with automatic Off and the existing disconnected-only On guard. Preserve network-change courtesy, timer and master toggle.
- [x] Remove active association, credential access, HTTP probes and obsolete diagnostic CLI; retain unrelated Bluetooth/link tests and add native adapter boundary regressions.
- [x] Update Settings labels/help and remove the separate return toggle; preserve the preferred list and timer.
- [x] Run tests, universal build and fresh review; resolve material findings before signing.
- [x] Install the same-signer Mac trial in place; verify worker, login, settings, internet and one installed app.
- [ ] Verify presence Off on the actual Samsung with Wi-Fi unchanged once its Tetherbug service is reachable. Keep the PR draft until real acceptance passes.

## Ledger

- Ruling: no new design approval round — the user explicitly selected presence-based Off and previously requested autonomous implementation for this project.
- Ruling: suppress automatic On while preferred presence is fresh — needed to prevent oscillation after Off; scanning only while hotspot On or Mac disconnected bounds radio work.
- Ruling: the preferred list itself configures the rule; remove the old independent enable toggle — the user made this part of Automatic Mode.
- Ruling: remove the old separate directed hotspot-cache seed — native macOS discovery owns that behavior; no extra scan path should evade the common minute throttle. Updated the live protocol guide.
- Review corrections: gate automatic On on the complete BLE handshake; apply courtesy only to Off; refresh the native link/SSID in completion decisions; stand down presence Off for unknown phone identity; preserve submission throttling across invalidation; filter saved preferred identities before radio work.
- Verification: policy RED/GREEN passed 155 tests before obsolete association tests were retired. Review regressions produced six expected failures, then the final native suite passed 120 tests, 0 failures (`/tmp/tetherbug-presence-final-suite.log`). Unrelated Bluetooth metadata, sleep, menu and login coverage remains; deleted tests concern removed association, Keychain, HTTP probe and restoration features.
- Delivery: installed `0.1.13-presence.1`, reviewed source `beeaf2e92c498817e631b15a897cad44dd4cb539`, from successful protected [trial run 45664912763](https://github.com/gbettineschi/Tetherbug/actions/runs/45664912763). Retained signer, universal architectures, new worker, native login enabled/no approval pending, preferred list and timer preserved, retired toggle removed, temporary previous bundle removed, Wi-Fi HTTP 200 confirmed. The temporary exact-branch signing policy was removed; only `v*` remains. No Android build, published release, tap update or merge.
- Device boundary: the Mac reports Bluetooth On but the phone disconnected. No actual presence-triggered phone Off is claimed for this build. The user has an outstanding readiness question; no further network switching is needed for that acceptance test.

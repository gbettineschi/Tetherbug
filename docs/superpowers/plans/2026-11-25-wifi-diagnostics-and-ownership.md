# Wi-Fi operation diagnosis and ownership Implementation Plan

> **For agentic workers:** Execute inline with superpowers:executing-plans and obtain focused independent review.

**Goal:** Identify scan versus association failures without changing the current Wi-Fi, and fix independently confirmed handover lifecycle defects.

**Architecture:** Keep public CoreWLAN and the current handover controller. Reuse fresh, interface-scoped discovery results instead of immediately rescanning. Preserve sanitized error stage/domain/code. Add one bounded scan-only diagnostic; it cannot authenticate, associate, disassociate, change power, read Keychain or change settings. Hold timed-out association intent until the real operation returns, then reconcile the observed link and honor external-choice cooldowns.

**Tech Stack:** Swift, CoreWLAN, existing power/sleep guards, existing retained signer.

**Spec:** Existing `2026-11-24-corewlan-link-design.md` plus the user's 25 November request to disambiguate EBUSY and audit correctness without changing their network.

## Constraints and review focus

- Keep automatic Wi-Fi return disabled; no live association during diagnosis.
- Do not infer saved-profile authentication support from scan success or a generic EBUSY error.
- Cache age, interface and awake generation must be checked; preserve exact saved raw SSID/security matching.
- Never release a blocking operation on logical timeout; never undo a later external network selection.
- Restoration must honor the latest external-change courtesy delay.
- Diagnostics expose counts, stage, duration and numeric errors, never passwords, identity or error userInfo.
- Install one app in place with the retained signer and preserve pairing/settings.

## Task1: Regression coverage and minimal lifecycle corrections

- Add failing cases for late association timeout while still on the original network, and restoration retry during a new courtesy delay.
- Add cache freshness/interface/generation and sanitized phase-error regressions.
- Preserve pending-target ownership until the blocking call completes; defer restoration rather than abandoning intent; gate restoration retries on courtesy.
- Reuse a fresh one-shot discovery snapshot; otherwise perform a directed scan with labelled failure.
- Run the full native suite; review the change.

## Task2: Bounded read-only diagnosis

- Add an internal signed-app CLI diagnostic that checks FullWake, existing Location authorization and saved target; executes at most discovery+directed scans and reports sanitized results.
- It must not contain or call association/credential/power-changing operations. Stop after a failed discovery or absent target.
- Stop the worker gracefully and acquire its existing exclusive lifetime lock for the entire diagnostic, including preflight. Refuse a running worker or another diagnostic. Reopen the app even after diagnostic failure or timeout. macOS and other apps remain outside this lock.
- Build/sign with existing identity, install in place with switching disabled, run the scan-only diagnostic once, and record exactly what it establishes.
- Capture no live credentials and perform no additional network switch. Keep the PR draft unless a later authorized handover passes.

## Verification so far

- Added timeout/late-completion/courtesy regressions; observed expected failures before the fixes. The final strengthened restoration regression failed before retaining ownership through observed-link reconciliation.
- Native suite: 140 tests, 0 failures after corrections (`/tmp/tetherbug-wifi-reviewed-green.log`).
- Focused independent review identified and corrected diagnostic contention, early power gating, raw-byte saved-target validation, retry preservation and credential-stage classification.
- No live association has been attempted for this audit. The earlier generic error cannot retrospectively distinguish directed scan from enterprise association.

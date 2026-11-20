# Stable signing implementation

Spec: ../specs/2026-11-20-stable-signing-design.md

1. Adapt the existing tested Keepresso archive boundary and exact project signer for the Tetherbug bundle. Test malicious archives, wrong identity, broad requirements, no candidate execution, failed imports and cleanup.
2. Separate keyless package building, protected signing and publication. Add a Mac-only exact-source trial. Test the workflow guard and publication refusing an ad-hoc or mismatched package. Keep Android signer untouched.
3. Use a temporary test-only certificate/keychain to prove two changed bundles retain the same DR, rejecting a different signer and tampering; do not touch live privacy permissions. Run Mac/release tests and an independent review.
4. Report the concrete result and obtain explicit activation of the new persistent key/custody. After activation, install two signed candidates in place, ask only for required initial OS approval, verify retention, then resume Bocconi test. No release before acceptance.

Ruling: Existing feature worktree is isolated and reused; implementation is authorized by the prior autonomous-work instructions and the request to follow Keepresso. Creating production credentials remains an explicit activation boundary.

## Preparation evidence

- 101 Mac tests passed; 13 release/environment/publication tests, 14 archive tests and four CI-wrapper tests passed.
- Actual temporary-certificate integration passed for two changed bundles: same exact DR; wrong signer, wrong incoming ID and tampering rejected; real archive and CI import/cleanup verified. No installed app, TCC grant, trust or Android change.
- actionlint 1.7.12 and shellcheck 0.11.0 passed on the changed workflow/scripts; tools ran from temporary directories and were removed.
- Fresh independent review found no material issues. Production key/environment provisioning, hosted signing and two installed-update permission acceptance remain pending explicit activation.
- The handover preference remains held; the owner interrupted before any network mutation. Resume the Bocconi test only after signature acceptance.

## Owner-authorized activation — 20 November 2026

- Owner approved the same free setup as Keepresso. Created Tetherbug-only RSA-3072/SHA-256 identity valid three years.
- Verified owner-only environment review, no administrator bypass, and exact trial branch/version-tag rules before uploading. Three environment secrets confirmed; public certificate/fingerprints committed.
- Temporary generation/export files removed. No personal keychain import, global trust, TCC or app change. No independent backup created.
- Next: exact-source Mac-only A/B signed trials; actual grant retention and Bocconi handover remain pending.

## Hosted runner follow-up

- The macos-15 runner imports both retained and ephemeral identities but signing reports that the specified keychain item cannot be found. The same actual fixture passes locally. No installer was produced or installed, and cleanup succeeded.
- Safe diagnostics disclose only fixed tool/operation labels for production signing; keyless ephemeral fixtures also report password-redacted tool errors. Regression tests cover redaction.
- Ruling: align both keyless Mac build/self-test and the fresh signing-only job with Keepresso’s verified hosted `xcode-27` runner; its successful trial job metadata confirms GitHub-hosted execution. Preserve the retained identity, strict requirement and protected environment. Do not change trust or guess at key/ACL replacements. Confirm with the actual fixture before loading production keys.

## Signed A/B ready; initial grant handoff

- Hosted actual fixture and both retained-key signing workflows passed at source a9a0a49. A installed in place; one actual app, managed service running, pairing retained, Bluetooth live.
- B downloaded and checked against public certificate, source, receipt hash and strict code signature. Same DR, different signed bytes. No B install yet: establish A’s usable Wi-Fi grant first.
- A’s existing-network Wi-Fi check did not complete; restored phone hotspot Off, held handover and cleared the test-created pause. Asked owner to enable Preferred Wi-Fi and check initial Location access; CUA screen capture unavailable.
- Remaining: A Wi-Fi usable, B installation plus actual grant retention, real Bocconi switch. Release/merge remain held.

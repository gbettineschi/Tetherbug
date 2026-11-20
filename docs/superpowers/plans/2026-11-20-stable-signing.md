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

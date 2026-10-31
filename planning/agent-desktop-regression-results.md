# Interaction migration regression results

31 October 2026

## Changes
- Synchronized Relay-owned LiteRT native schemas with the updated executor: observe_app now advertises optional mode, root_ref and query; press_control advertises optional action. Existing required arguments remain unchanged.
- Added model argument-preservation, schema optionality, direct SDK execution refusal, malformed/error envelope, Unicode snapshot, empty-find, invalid-reference and unsupported-action regression tests.
- Exposed envelope parsing internally for deterministic tests; no new public API.
- Added an opt-in live test using only Relay Accessibility Fixture, with a per-launch token and temporary JSON oracle. No user accounts, microphone or permission changes.

## Results
`RELAY_RUN_AGENT_DESKTOP_TESTS=1 swift test`

**408 tests across 66 suites passed**, 9 optional tests skipped. Runtime 9.629 seconds after build.

Live agent-desktop test passed:
1. Launch isolated fixture and verify clean initial state and launch token.
2. Snapshot and find a unique named text field using the library's normalized roles.
3. Enter Unicode text: sf.webm — Résumé 日本語 👋.
4. Find a fresh Apply button reference and click it.
5. Verify exact input/result and exactly one click through the separate fixture oracle.
6. Verify text through a new accessibility snapshot.
7. Confirm disabled-button click reports failure and click count stays unchanged.
8. Confirm a nonexistent control returns no invented element references.

The first live attempt caught incorrect AX-native role names in the test. Updated the fixture test to use agent-desktop roles `textfield` and `button`; final run passed.

## Reproduce
From the Relay repository, with existing Accessibility access for agent-desktop and the bundled fixture available:

```sh
RELAY_RUN_AGENT_DESKTOP_TESTS=1 swift test --filter AgentDesktopFixtureTests
```

Default `swift test` runs deterministic regressions but skips live interaction. The live test refuses to request permissions and refuses to reuse an already-running fixture.

## Limits
This validates bridge-level interactions in a controlled native fixture. It does not qualify end-to-end local-model planning, arbitrary applications, Gmail/browser tasks, production review/cancellation across the migrated backend, or stale-reference behavior. The nine older optional desktop/model/speech tests were not enabled. Installed Relay.app was not rebuilt or replaced.

Full log: `/tmp/relay-migration-final-tests.log`.

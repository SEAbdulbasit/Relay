# Updated interaction library test results — 31 October 2026

## Result
The suite is not fully green. Swift compilation succeeded, but one schema-contract test failed with six assertions.

- `swift test`: 398 tests reported across 64 suites; one failing test, six issues; nine optional tests skipped.
- `python3 -m unittest discover -s Scripts/Tests -v`: 10 passed.
- `python3 e2e_tests/runner.py`: 150 passed. These are largely source assertions and local website checks, not evidence of live human-style computer use.
- New `AgentDesktopBridge` integration suite: both tests passed. Vendored agent-desktop 1.0.2 resolved, dylib loaded with ABI 6, version and permission-query envelopes succeeded. Permission-query success does not imply permissions are granted.

## Failure
`nativeSchemasMatchExecutorNamesFieldsAndRequiredArguments` in `Tests/RelayTests/LocalModelTests.swift`:
- The executor advertises inspection fields `mode`, `query`, and `root_ref`, but the native model schema only advertises `bundle_id`.
- The executor advertises click/action field `action`, but the native model schema only advertises `bundle_id` and `element_id`.
- Two property-set assertions and four missing-type assertions fail. The native LiteRT tool definitions need to match the updated executor before these new arguments can be reliably requested by the model.

## Limits
No live microphone capture, permission changes, private inbox actions, or desktop clicks were performed. Optional desktop, model-inference and speech-render tests were not enabled by this run. Passing bridge tests establishes loading and basic CLI communication, not click/type/readback or stale-reference/cancellation correctness with the new library. The existing optional accessibility fixture should be qualified against the migrated backend separately.

## Logs
- `/tmp/relay-update-tests.log`
- `/tmp/relay-update-script-tests.log`
- `/tmp/relay-update-python-tests.log`

No source code or installed app was changed by this test run.

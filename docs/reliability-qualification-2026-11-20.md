# Relay reliability and remaining-gap qualification — 20 November 2026

This continues the product review with implementation and qualification of its remaining gaps. Existing uncommitted changes were preserved. Three parallel agents own recovery, background/providers, and first-success/sources; the coordinator owns navigation/search, integration and live inspection.

## Priorities and implementation

| Gap | Action / evidence | Qualification |
| --- | --- | --- |
| Declined tasks could still Continue | Store continuation authority now distinguishes explicit refusal and recovery phases; an ordinary successful idle reply cannot resume | Deterministic lifecycle tests added; integrated run pending |
| Stale errors after successful continuation | Clear old task error only when an eligible continuation begins | Failure → explicit retry test added |
| Login item unavailable | Explicit registration retry from `.notFound`, current status re-read, real errors; no automatic preference change | Injected ServiceManagement tests; actual registration remains a user-controlled action |
| Background sleep/power/thermal recovery | Persist in-flight marker; enforce interruption/admission states and preserve explicit Stop while callbacks settle | Scheduler tests added; real lid/wake hardware qualification separate |
| Provider failure/retry | Inert fixtures cover timeout/disconnect/cancel/partial-stream/auth/rate limiting for LM Studio/OpenRouter/Responses | 18 qualification cases added; no real credentials or paid calls |
| Evidence-backed plan progress | Stable app UUIDs, actual attempt/review/reconciliation/step-check transitions, revision-fenced Store projection and accessible Activity rows; earlier-run checks are not renewed proof | Five orchestrator cases plus Store stale-callback regression |
| Real onboarding first success | Explicit editable calculator trial uses production local tool, checked result/evidence and retry; no model/download prerequisite | New production tool tests and final live check |
| Calendar permission confused with inclusion | Separate exact calendar selection and session preparation opt-in using real existing scheduler/ingestion | Existing scoped scheduler tests + final source-control UI check |
| Knowledge results opened root | Exact note destination survives palette dismissal, re-resolves current notes, respects unsaved-edit guard and reports missing note | New destination tests + live note navigation |
| Main-actor palette scans | Cancellable concurrent search, bounded result collection and short input debounce; stale tasks cannot publish | Search semantics/cancellation tests + synthetic benchmark |
| Vendored desktop engine incorrectly reported incompatible | Runtime/library ABI is7; bridge expected6 | Direct runtime/header evidence, strict version check and regression tests |
| Duplicate tool definitions silently discarded | Validate uniqueness/format before Codex prompt/schema/parser use | Existing failing assertion retained + regression tests |

See lane evidence: [recovery](reliability-recovery-2026-11-20.md), [background/providers](reliability-background-providers-2026-11-20.md), [first success/sources](reliability-first-success-sources-2026-11-20.md), [summary/vision](reliability-summary-vision-tests-2026-11-20.md).

## Measurement

A local synthetic archive benchmark used60 threads ×100 messages × roughly4KB/message (within the archive's thread/storage bounds). Original command-palette full filtering took138ms for a missing term; bounded filtering alone took263ms in that run and therefore does not establish a general speedup. A common matching query stopped after8 results (24µs versus130µs). The significant corrective action is moving long scans off MainActor with cooperative cancellation, not claiming faster model inference or real frame-time gains. Measurements are synthetic, unoptimized interpreter results; script `/tmp/relay-palette-benchmark.swift`.

## Baseline and validation policy

Before implementation was compiled, the unfiltered default app suite ran2046 tests in319 suites and reported29 issues; the journal suite ran58 tests in10 suites and passed. Log `/tmp/relay-reliability-baseline-full.log`. Concrete failures include ABI mismatch, duplicate-schema admission, cross-mode local-runtime reuse, and deadline/polling failures. The previous82-test product pass never established full-suite success.

Failures are rerun in isolation. Assertions and deadlines are preserved; busy-yield polling may be replaced with suspending polling when contention is the cause. No flaky or failing cases are silently excluded. Final test/build/live outcomes are appended after integration.

## Remaining boundaries

The original per-plan-step gap is now implemented through explicit execution snapshots; see [plan-progress evidence](reliability-plan-progress-2026-11-20.md). Observation checked and Step checked describe actual accepted engine outcomes and never imply whole-goal completion. Earlier cursor entries on resume are labeled not rechecked, and snapshots are ephemeral display data rather than restart/execution authority. Single-agent plans without step events retain neutral proposed rows.

Real OAuth sign-in, paid provider/account failures, irreversible external sends, actual OS wake/lid cycles, full VoiceOver/audio/hardware gestures, and destructive reset/uninstall are not inferred from fixtures. Tests use temporary synthetic files and inert providers; user data/account access is not expanded as a verification shortcut.


## Qualification updates before final integration

- First targeted integrated run:185 tests in22 suites passed (`/tmp/relay-reliability-targeted.log`). Includes provider faults, strict runtime identities, ABI7, schema validation and lifecycle fixtures.
- Unfiltered explicit `--no-parallel` rerun:2071 app tests in324 suites reported7 issues, all from two CompletionLoop test cases using a500-yield iteration limit instead of elapsed worker completion;58 journal tests passed. The helper now suspends within a3-second deadline and retains all completion/outcome assertions, cleaning up a timed-out task after reporting failure. This is separate from the prior full-concurrency deadline contention. Final run below will include the helper correction.
- Independent reviews added and tested in source: immediate post-decline new instruction identity; standalone voice cancellation after completed/failed tasks; successful-cycle cadence measured from completion; a20-minute scheduler watchdog releasing the timed awake assertion while preserving the physical draining slot.
- Python packaging/vendor/fixture unit checks:12 passed (`/tmp/relay-reliability-python.log`).

### Additional confirmed Knowledge draft-loss fixes

Parent page/thread/setup navigation previously destroyed the Knowledge reader's inline draft without invoking its existing Save/Discard/Cancel prompt. Move/Sheet also reopened the original saved note; Chat with Note staged old content before a navigation decision. All three now use a deferred, owner-scoped navigation guard. Save failure or Cancel leaves the draft and departure side effects untouched; Save re-resolves the current note before opening its sheet or staging chat. Seven tests cover the real decision component and persisted-note resolution; parent/menu integration is subject to the live pass.

### Full-run stall diagnosis

A subsequent full serial run stopped making progress after Activity presentation tests. Sampling showed idle async executors; the buffered log hid the actual failing prerequisite. A PTY reproducer exposed `AdversarialMultiAgentStressTests.declineStopsPlanWithoutReplayingAction`: its 500-yield loop could finish before review arrival, `denyReview()` then did nothing, and the test awaited settlement indefinitely when review subsequently appeared. Yield-count waits in that suite were replaced by bounded suspending prerequisite waits, with required review identity and explicit cleanup of owned barriers/reviews. Existing outcome/evidence/no-replay assertions remain intact.

After that correction, a serial regression run passed **66 tests in 11 suites** (`/tmp/relay-reliability-final-regressions.log`), including the adversarial suite, completion loops, real plan progress, task continuation, scheduler watchdog/cadence, palette search and Knowledge guards. An unfiltered serial qualification with owned local HTTP/MCP fixtures enabled is recorded below once complete.

## Final integrated automated qualification

The unfiltered deterministic command completed successfully:

`RELAY_LMSTUDIO_LOOPBACK_PROTOCOL_TEST=1 RELAY_OPENROUTER_LOOPBACK_PROTOCOL_TEST=1 RELAY_CUSTOM_RESPONSES_LOOPBACK_PROTOCOL_TEST=1 RELAY_MAIN_MCP_LOOPBACK_PROTOCOL_TEST=1 RELAY_CODEX_READINESS_TEST=1 swift test --skip-build --no-parallel`

- **2,088 app Swift Testing tests in 326 suites passed** (124.469 seconds).
- **58 journal Swift Testing tests in 10 suites passed** (3.823 seconds).
- **24 XCTest checks passed**.
- **78 opt-in tests remained skipped**, principally real hardware/UI/model/account gates. Skipped gates are not counted as verified capabilities here.
- Log: `/tmp/relay-reliability-qualified-full-final.log`.
- The enabled loopback gates exercised real URLSession sockets, split UTF-8 streams, scoped synthetic credentials, exact tool-call/result IDs, no redirect following, cancellation/draining and production Store MCP approval/receipt paths. Existing Codex sign-in readiness also passed without networking.
- Twelve Python fixture/vendor/packaging checks passed separately. Targeted source/test whitespace checks passed.

The default concurrent test run is **not** claimed green. It exposed strict-deadline contention; serial execution is the qualified configuration. Both diagnosed yield-count test races were fixed without removing their behavioral assertions. No test was disabled to obtain this result.

The existing signed-in Codex CLI also passed the explicitly enabled live synthetic planning test: one test, 6.499 seconds (`/tmp/relay-reliability-codex-live.log`). It submitted only the canned request to return “Relay synthetic planning ready.” with no advertised tools or private source context; returned the exact response and no tool calls. This establishes one current-provider smoke result, not every account failure or native desktop workflow.

## Live development-bundle verification

The signed development bundle built and passed strict signature verification (`/tmp/relay-reliability-final-app-build.log`). Live checks used synthetic content and preserved existing conversations, settings, and source selections.

- Onboarding calculator: actual `(18 + 24) * 3` returned 126; `2 / 0` showed the real division-by-zero error; explicit retry `21 * 2` returned 42 with local-tool evidence.
- Calendar source: granted permission remained visibly separate from zero selected calendars and disabled/off daily inclusion; no calendar, scope, schedule or permission was changed.
- Login item: the current `.notFound` state exposes explicit Retry enabling at login and accurate recovery guidance. Registration was not performed on the user's behalf; actual macOS enable/approval remains unqualified.
- Created one clearly synthetic note, **Relay reliability verification**, to test real file persistence. Home navigation prompted Save/Discard/Cancel; Cancel retained the exact unsaved body. Move/Sheet prompted again; Save opened the sheet with the updated persisted body. The note remains as a reviewable test artifact.
- Command-palette search returned that note and opened its exact reader and saved body, rather than the Knowledge root.
- A fresh synthetic workspace request performed two calculator calls and returned 156 and 163 with separate checked Activity records. It did not read files or apps.
- A subsequent synthetic explanatory request was stopped during planning. The UI showed Task stopped, preserved Activity and exposed distinct Inspect activity and Resume controls. Explicit Resume began a new planning attempt; its final outcome is recorded below.
- Live inspection also corrected two presentation-only defects for the final incremental build: Knowledge now includes native cached sources in its unique source count, and onboarding exposes only the current step as selected in accessibility.

The live stopped request resumed successfully and returned the requested one-sentence explanation; the stopped-state recovery controls disappeared after completion. This qualifies actual planning interruption and explicit continuation through the existing Codex workspace. It does not claim live external-app input interruption/readback or a physical sleep/wake cycle. Known partial-effect/no-replay paths are covered by inert integration fixtures.

The final incremental build includes only the subsequently observed source-count and progress-rail accessibility corrections; no full-suite rerun was needed for those presentation changes. Compilation/signature and focused live verification are recorded with `/tmp/relay-reliability-shipping-build.log`.

### Remaining live qualification boundaries

- Real login registration/approval, logout/login, physical sleep/lid/power changes, multi-display touch/voice gestures, and full VoiceOver/text-scaling traversal remain unperformed.
- Only the existing Codex account received a real provider smoke request. Other providers were qualified through inert failures and real owned-loopback HTTP, not their live accounts.
- The live arithmetic and Stop/Resume requests used the current single-agent workspace configuration. Multi-agent step transitions, reconciliation, denial and stale callbacks have actual engine/Store fixture coverage; a live external-app multi-agent operation was not performed.
- The new Knowledge guard covers page/thread/setup departures and Move/Sheet/Chat intents. Window/app termination with an unsaved inline editor was not exercised or redesigned; it is not a claim of crash/quit draft recovery.
- No irreversible reset/uninstall or external send was executed. No new source scopes, credentials, permission grants, login item, or schedule was enabled by verification.

Final presentation verification: the signed bundle showed `54 sources · 1 note`, including cached native records. The onboarding rail exposed Completed for prior steps and Current step only for the selected step. Live AX inspection also caught a missing button trait after child-label suppression; an explicit button trait was added. The rail was extracted into a small view builder to keep SwiftUI compilation bounded. Final compilation and live role checks follow below.

Final bundle build passed (40.76 seconds), and `codesign --verify --deep --strict --verbose=2 build/Relay.app` reported valid on disk and satisfied its designated requirement. Live AX verification confirmed all five rail controls are buttons; only the current step is selected, prior steps report Completed, and future steps report Upcoming. Returned to the completed workspace with the synthetic resumed answer intact. The final presentation-only changes were compiled and checked live after the full serial test qualification.

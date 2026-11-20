# Execution recovery reliability — 20 November 2026

## Scope and evidence

This pass inspected the production `AssistantStore` task lifecycle, `AssistantConversationHistory` call checkpoints, `MultiAgentContinuation` factual receipt cache, `MultiAgentStepCheckpoint`, the multi-agent orchestrator, and existing executor/native-control/journal integration tests. It adds deterministic Store integration coverage using scripted completion handlers and inert tool dispatchers. It does not certify live model providers, actual desktop mutations, permission prompts or abrupt process termination on this machine.

## Confirmed defects and corrections

| Severity | Component | Before | Correction | Evidence |
| --- | --- | --- | --- | --- |
| High | Explicit review decline / Continue | `denyReview()` only resolved a Boolean continuation. The Store advertised `canResumeCurrentTask` after denial, and generic Continue began another logical-task run without a new instruction. The single-agent route relied on model text not to reoffer the declined action. | Remember the explicitly declined logical task ID. Both the affordance predicate and `resume()` require a fresh user request for that task. Internal Stop/steering resolution does not mark a user decline. New requests clear the old marker and create a new logical identity. | Single/multi-agent fixtures assert no additional inference, review or dispatch after repeated Continue, unchanged owned file, then successful new informational request. |
| Medium | Successful / idle task | `canResumeCurrentTask` remained true for any nonempty active objective with a journal run, including a successful informational response. Calling Continue again started unnecessary inference. | Generic continuation is restricted to `.stopped`, `.failed`, `.needsInput`. Exact-unsent storage repair retains its separate existing path. | Inert calculation fixture asserts one dispatch, two original model turns and no additional work from repeated Continue. |
| Medium | Successful recovery error feedback | Generic `resume()` preserved the old `errorMessage`, so a successful answer could keep displaying the preceding provider failure. | Clear the prior task error only after the task passes recovery eligibility checks. A failure in the new run sets its own real error. | Scripted failed-then-successful inference fixture asserts the error clears and an unsent draft remains intact. |

The decline restriction is intentionally scoped to the existing logical task, not a permanent ban on the tool or content. Sending a new instruction starts a new task and may lead to a new explicitly reviewed proposal. No approval ticket, source grant, native action capability or persisted execution instruction is created by this change.

## Stop, partial effects, rejection and restart findings

- `stop()` revokes action capabilities, invalidates approvals, cancels the active planner, resolves any review, records the interruption, and reports that in-flight work can still finish. `beginRun()` awaits the previous task and its factual checkpoint before replacement planning. Added a fixture that calls Stop and Continue rapidly while one inert effect is suspended: the unstarted second batched request must never dispatch, the late first result must appear exactly once in well-formed resumed model input, and the unsent draft must survive.
- Existing journal checkpoint tests cover result-save failure and retry without repeating a dispatched action; existing direct-action paths retain `directAttemptTaskID`/known results for the same logical task. Those mechanisms were preserved.
- Multi-agent `MultiAgentStepCheckpoint` already distinguishes executor start from possible dispatch, retains an app-owned plan cursor, and resumes possibly dispatched executor steps through fresh read-only reconciliation instead of recreating the old executor proposal. It also retains declined-step state. The Store-level decline change makes the public affordance match that restriction and covers the single-agent path.
- `MultiAgentContinuation` stores bounded factual receipts and source validators for the same process. It has no replay ticket or dispatch closure. It does not deserialize receipts into execution authority after restart.
- History restoration sets `restoredTaskNeedsNewInvocation`; previous window readers, grants, review continuations and executable calls are not minted from conversation history. Added a real temporary-journal restart-after-decline fixture: conversation facts restore, pending review stays absent, and calling Continue performs zero inference and zero dispatch. The owned file stays unchanged.
- This work does not claim universal semantic duplicate prevention. In particular, a malicious or faulty planner can request a semantically similar action with different tool arguments. Device-specific one-use capabilities and journal proposal checks remain the authority. No generic text-matching deduplication was added: identical scroll, typing or open operations can be legitimate after a genuinely fresh observation or new instruction.

## Per-plan-step progress feasibility

The current visible `currentPlanSteps` is a string projection emitted only when the planner supplies a plan or a cached plan is restored. The production orchestrator has richer state: `PlanStep`, app-owned checkpoint entry tokens, a cursor, an executor possible-dispatch stage, and independent critic turns. However:

1. `onPlanUpdate` exports titles only and is not emitted at every enter/complete/reconciliation transition.
2. A checkpoint cursor means the scheduler accepted a step outcome in that run; it is explicitly not proof that the user's goal is currently satisfied.
3. A restored plan marks earlier steps `.skipped` in the new blackboard while its factual receipts require fresh source validation. Reusing these statuses as green verified UI would again overclaim historical work.
4. Model plan IDs and titles may repeat; any future UI snapshot must preserve app-owned index/token identity rather than keying by model text.

A safe follow-up can expose immutable scheduling snapshots with explicit `planned`, `running`, `paused`, and `settled in earlier run` wording, plus a separate current-evidence verdict. It needs a new callback at each scheduler transition and tests for duplicate model IDs/titles, late callback revocation and resumed reconciliation. This pass keeps the neutral plan display from the product review. It does not infer per-step verified completion from phase, cursor, role change or a model narrative.

## Added deterministic tests

`Tests/RelayTests/TaskContinuationAuthorityTests.swift`:

- Explicit decline requires a new instruction (single-agent and multi-agent cases).
- Repeated Continue after successful response performs no work.
- Rapid Stop/Continue waits for the single in-flight effect and preserves its factual result.
- Restart after decline restores facts without action authority or replay.
- Successful recovery clears the previous inference error and preserves the unsent draft.

Fixture files live only under uniquely owned temporary directories. Tool dispatch closures are inert; no browser, application, account or remote provider is controlled. The restart fixture uses the actual conversation journal and a second Store instance after closing the first writer; it is not an abrupt-crash process test.

## Validation status

- Swift frontend parsing passed for the changed Store and new tests.
- `git diff --check` passed for the changed Store and test file.
- Integrated compilation and test execution are owned by the coordinating agent. Until those results are recorded, the assertions above describe added regression coverage, not a claimed runtime pass.
- The coordinator reported unrelated baseline failures in native vision runtime identity and a notch-voice predicate during its full baseline suite. This lane does not alter those components or classify those failures as caused/fixed by this change.

## Remaining live verification

Real permission rejection; installed provider offline/reconnection; actual desktop interruption and current-window reconciliation; long-running process termination; and UI focus after recovery require the coordinator's permission/account-dependent live pass. Existing deterministic test coverage cannot establish those outcomes.

## Baseline integration defects corrected during follow-up

- **Desktop FFI compatibility:** the vendored `agent-desktop` is version 1.3.1 and its header declares ABI 7, while the bridge and its integration test still expected ABI 6. A direct read-only C `dlopen` diagnostic observed `ad_abi_version() == 7`, `ad_init(6) == -10`, and `ad_init(7) == 0`. The bridge now expects the actual vendored contract (7), reads the runtime ABI before initialization, fails closed on mismatch, and reports the observed major rather than echoing the expected value. The exact integration assertion now expects 7; added checks bind the expected major to the vendored header and verify that a deliberately incompatible expectation is rejected. These calls do not create a desktop adapter or request permissions.
- **Codex action schema ambiguity:** `outputSchema()` deduplicated definitions before checking name uniqueness, making its duplicate guard ineffective. Conflicting definitions could silently use whichever happened to appear first. Shared strict tool-name validation now applies to prompt generation, schema construction and parsed reply validation. Duplicate names (including definitions with different argument schemas), invalid names and excessive schema counts fail before dispatch instead of being silently discarded. Added tests cover prompt/schema/parser agreement; the original duplicate-rejection assertion remains unchanged.
- Swift frontend parsing and changed-file whitespace checks passed after both corrections. Integrated test results remain owned by the coordinator until recorded below.
- A read-only review of `CommandPaletteSearch` and `KnowledgeNoteDestination` found no material defect in the inspected code: search results preserve URL note identity and cancellation checks; note navigation re-resolves the exact graph identity against current vault contents and preserves the existing unsaved-editor guard. This source review does not establish a rendered keyboard/navigation pass.

### Full-suite timeout triage (read-only)

The coordinator's baseline log also recorded deadlines in `ordinaryRegisteredStepSettlesInnerCheckpointsWithoutAnOuterIntent`, multi-agent destructive-action review, and the approved hosted-file-read scenario. Inspection showed their wait loops already suspend using 1–2 ms sleeps; they are not busy-spin loops. The first two 8-second deadlines resumed approximately 2.4 seconds after expiry during a heavily concurrent full suite, with total test times around 15.7–15.9 seconds. The hosted-file scenario failed after its 10-second test wait while the Store was still acting and file extraction remained inside the worker's 15-second extraction window. These traces support scheduler/test-budget contention, not a proven production deadlock or tool failure. Assertions and deadlines were left unchanged. Isolated reruns and bounded overall test concurrency are needed before classifying these outcomes; no timeout pass is claimed here.

## Independent-review corrections and progress integration

Two additional lifecycle edges were identified by independent review and corrected:

- **Immediate instruction after Decline:** `denyReview()` resumes the awaiting coroutine but does not synchronously leave `.awaitingReview`. An immediate accepted user message previously entered the steering branch, retaining the declined logical-task ID and invalidating its old multi-agent checkpoint. The new instruction now enters the ordinary fresh-task path even while the denied coroutine drains. It owns a new logical task, source authority and checkpoint, while the existing `beginRun()` still cancels and awaits the old task before new planning. Parameterized single/multi-agent coverage declines, sends immediately without suspension, fails the replacement provider, then continues successfully. It asserts actual journal relations `newRequest(new identity)` followed by `resume(same new identity)` and no declined file mutation.
- **Standalone voice cancellation:** Stop previously treated `voiceWasBusy` as a reason to set the old conversation phase to `.stopped`, even after the conversation had finished. Cancelling dictation could therefore turn a completed task into a resumable execution. Standalone voice/audio cancellation now returns before touching conversation history, task capabilities or phase. Fake-voice tests cover both a completed conversation (no later inference) and a failed conversation (its legitimate recovery remains available), with no microphone or permission request.

The earlier per-step feasibility assessment is superseded by a coordinated implementation of explicit engine progress snapshots. `AssistantStore.currentPlanProgress` is a read-only array of `PlanStepProgress`. The orchestrator lane emits snapshots at actual scheduling/review/reconciliation/evidence transitions; the Store accepts a callback only when both the run revision and logical task ID still match. Stop marks only in-flight entries as stopped, retaining earlier checked states; journal repair/finish failures mark in-flight entries as needing attention. Fresh tasks, exact-unsent tasks, context invalidation, transcript editing, clearing and thread selection discard these ephemeral snapshots. They are not serialized or restored as execution authority.

A deterministic Store fixture uses duplicate model step IDs and titles, verifies distinct app UUID identities, stops a suspended inert executor, starts a replacement informational request, and asserts that late old-run callbacks cannot repopulate its cleared plan. These changes expose engine facts; they do not infer whole-goal completion from role, run phase or model prose. Integrated compilation and execution of the new follow-up cases remain pending the coordinator's run; parsing passed.

### Confirmed full-serial fixture hang and correction

The later serial run appeared to freeze after Activity presentation tests because redirected output was buffered. A pseudo-terminal rerun exposed the actual next events: the first two adversarial tests passed; `declineStopsPlanWithoutReplayingAction` exhausted a fixed 500-yield loop before its review arrived. Its non-fatal expectation failed, `denyReview()` ran with no pending review, and the following unbounded settlement await waited forever when the real review arrived afterward. This is a confirmed test-fixture synchronization defect, not evidence of a framework/discovery hang or production deadlock.

All yield-count polling in `AdversarialMultiAgentStressTests` was replaced with elapsed-clock bounded, suspending prerequisite waits. Review existence and exact action name are now required before declining. The review, planner-barrier and executor-barrier fixtures clean up on prerequisite failure by stopping the Store, releasing any owned continuation once, awaiting settlement and rethrowing. Existing action/evidence/review assertions remain; the fixtures no longer continue after a failed prerequisite and leave an unresolved review. Parsing and whitespace checks passed. Runtime rerun is coordinated by the root agent.

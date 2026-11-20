# Background and provider reliability — 20 November 2026

This lane preserves the existing dirty working tree. Its changes are confined to launch-at-login recovery, plugged-in analysis scheduling and deterministic tests. It does not register login items, enable preparation, create OS wake schedules, change permissions, install services, touch real credentials or send paid provider requests during validation.

## Findings and implementation

| Priority | Confirmed issue | Correction | Location |
| --- | --- | --- | --- |
| P1 | `.notFound` login status made registration permanently unavailable: both controller and view refused an enable attempt. | Offer explicit retry from `.notFound`, call the existing main-app registration API only on that user action, and reread actual macOS status. Failures stay visible and approval remains a separate state. | `LaunchAtLoginView.swift`, `LaunchAtLoginTests.swift` |
| P1 | An automatic cycle could start after its durable run reservation silently failed to save. | Persist before acquiring the awake lease or entering the pipeline; refuse automatic execution on failure and surface a storage error. A manually requested run can still proceed with explicit current-session error feedback. | `PluggedInAnalysisScheduler.beginCycle/persist` |
| P1 | Canceling before the queued task entered its runner could still start the ingestion callback. | Check task cancellation before invoking the pipeline. | `PluggedInAnalysisScheduler.beginCycle` |
| P1 | Explicit Stop could become a resumable pause if an idle/power/sleep tick arrived while an uncooperative callback drained. | Preserve the terminal Stop reason; repeated suspension events cannot overwrite it. The persisted marker also excludes explicitly stopped runs before callback settlement. | `PluggedInAnalysisScheduler.suspendActiveCycle/persist` |
| P1 | Abrupt process exit during a running cycle persisted no in-flight flag. A reopened scheduler waited the four-hour cadence despite an interrupted pipeline. | Persist an optional `interruptedRun` marker; restore continuation eligibility from it. Old version-1 snapshots without the optional field continue decoding. Source-item checkpoints remain owned by the underlying ingestion/vault pipelines. | `PluggedInAnalysisScheduler.PersistedState/restore` |
| P1 | Four-hour cadence preferred the run start even after a long successful completion, permitting an immediate next cycle. | Anchor completed cycles to `lastCompletedAt`; an explicit Stop has its own persisted four-hour suppression. | `PluggedInAnalysisScheduler.cadenceAnchor/nextScheduledDate/isCadenceDue` |
| P1 | Plugged-in analysis had neither an execution ceiling nor a bounded native idle-sleep assertion. | Add a 20-minute watchdog, kernel-timed IOPM assertion, and visible timeout result. Cancel/release immediately at expiry while retaining the physical draining slot; only settled timeouts may retry after backoff. Explicit Stop wins over timeout and suppresses automatic resurrection. | `PluggedInAnalysisScheduler.beginCycle/suspendActiveCycle/finishCycle`, `PreparationScheduleView.outcomeBadge` |
| P2 | Manual analysis bypassed known sleep and serious/critical thermal state until a later polling tick. | Refuse initial dispatch during sleep or thermal pressure; manual requests retain their existing battery/idle bypass when awake and cool. | `PluggedInAnalysisScheduler.runManualCycleNow` |
| P2 | IOKit lookup failure returned an assumed AC state, allowing unattended work on an unknown source. | Represent unknown power explicitly and defer automatic work. A genuine AC-powered desktop may still have no battery percentage. | `AnalysisPowerState` |

## Apple API evidence

Apple describes `.notFound` as a service lookup error; it is not a permanent capability declaration. `SMAppService.mainApp` represents the current application's login item, and `register()` is the supported registration operation. Successful main-app registration makes it eligible for future logins and may still require user approval. These documented semantics justify allowing a deliberate retry; they do not prove any individual developer bundle will successfully register.

Sources consulted:

- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Service registration states](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum)
- [Registering a service](https://developer.apple.com/documentation/servicemanagement/smappservice/3945413-registerandreturnerror?language=objc)
- [Unregistering a service](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister%28%29)

The default registration action now rejects a command-line process that is not inside an `.app` bundle with a bundle identifier and explains reopening Relay.app. It delegates signing, eligibility and approval checks to Service Management and surfaces its actual failure. No extra helper, entitlement, login database manipulation, automatic deregistration or private workaround was introduced. Actual registration from a signed/installed bundle remains a live OS check requiring a deliberate user action.

## New deterministic qualification

`LaunchAtLoginTests` adds two cases:

- Repeated status refreshes never register anything; an explicit retry from `.notFound` can reach `.requiresApproval`.
- A failed missing-registration attempt remains visible across refresh and can recover on a later explicit attempt.

`PluggedInAnalysisReliabilityTests` adds fourteen cases (including five parameter instances):

- Unknown power defers automatic execution.
- Sleep and thermal pressure reject manual starts before acquiring a lease.
- Stop before asynchronous entry never invokes the pipeline.
- Stop remains terminal while a late callback drains; late results do not mark completion.
- Sleep, battery, thermal, user activity and foreground-task interruption release the lease immediately, discard a late result and resume only once eligibility returns.
- An on-disk in-flight snapshot restores continuation without waiting four hours; the completed snapshot clears that marker, and Stop writes a terminal marker before settlement.
- Failed reservation persistence starts neither pipeline nor awake lease.
- A long successful run waits four hours after completion instead of immediately repeating.
- An injected watchdog expiry releases the awake lease while an uncooperative callback drains; no manual/automatic overlap starts, late success is discarded, retry backoff starts after settlement, and a later explicit Stop remains terminal (two parameter instances).

The existing Wave2 manual-thermal test now starts its run while cool and injects critical thermal pressure during execution. This preserves its original intent of checking interruption, while the new start-admission test covers already-hot hardware.

`ProviderFailureRecoveryQualificationTests` adds eighteen inert protocol cases:

| Provider | Injected failure modes | Required result |
| --- | --- | --- |
| LM Studio | Timeout, disconnect, cancellation, partial SSE stream, HTTP 401, HTTP 429 | No published partial reply/action; no automatic retry; after settlement, a fresh explicit request succeeds. |
| OpenRouter | Same six modes | Same; synthetic in-memory key custody only. |
| Responses API | Same six modes | Same; inert local endpoint and in-memory credential store only. |

No production provider client change was needed based on this inspection. Existing tests additionally exercise uncooperative HTTP drainage, provider switching, credential rotation, source-revocation checks, vision receipt invalidation, duplicate/opaque protocol identities and bounded transport responses. These protocol fixtures demonstrate control/error behavior, not real model quality, account readiness, provider availability or cost.

## Existing background mechanisms reviewed and retained

- `PreparationScheduler`: explicit opt-in; per-local-day reservation; six-hour catch-up window; source/calendar scope validation; bounded retry after abrupt exit; cancellation before inference publication; 20-minute automatic limit; power/thermal deferral; release before an uncooperative callback drains.
- Daily time policy and wake setup: skipped/repeated DST handling, local-zone changes, clock rollback protection, exact owned-event cancellation and duplicate suppression.
- Managed wake: signed helper requirement, macOS approval, explicit enable/removal, privileged connection identity and confirmation before uninstalling a helper with outstanding wake/sleep responsibility.
- Awake lease: scoped owner/token, heartbeat expiry, absolute time ceiling, external-power loss restoration, persistent recovery marker and leaving unrelated/preexisting sleep settings alone.

The wake/helper mechanisms were not changed speculatively. Their existing focused suites are part of the integrated verification request: `PreparationSchedulerTests`, `PreparationWakeSetupTests`, `ManagedPreparationWakeTests`, `ManagedPreparationAwakeLeaseTests`, plus the existing plugged-in cases in `Sentient31ParityTests` and `Wave2FunctionalityTests`.

## Verification status and limits

Swift parser validation passed for changed production files (launch-at-login, plugged-in scheduler and timeout outcome badge) and all new/updated tests. An integrated compile caught an SDK-unavailable UPS constant in the initial power-source check; it was removed before the next build. AC and battery source constants remain; other/unreadable source values defer automatic work.

The coordinating agent owns integrated compilation and test execution to avoid simultaneous SwiftPM builds. Until its results are recorded, the new tests are implemented assertions, not claimed passes. No login/logout cycle, lid-close session, physical sleep/wake/power transition, signed helper installation, live CLI authentication, real model load or paid cloud request was executed by this lane.

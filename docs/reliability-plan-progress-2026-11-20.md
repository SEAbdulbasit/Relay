# Evidence-backed plan progress — 20 November 2026

## Engine projection

`PlanStepProgress` is a presentation-only immutable snapshot value. It cannot authorize dispatch or replay a step. App-owned UUIDs come from `MultiAgentStepCheckpoint.Entry.token`, rather than model IDs or titles, so repeated titles and IDs remain distinct. A first run whose plan cannot be safely retained gets ephemeral per-run UUIDs; no resumability is invented for unavailable cached plans.

The orchestrator publishes a complete snapshot at plan admission and explicit transitions:

| State | Meaning and source |
| --- | --- |
| Planned | The planner supplied this step; it has not entered execution |
| In progress | The engine entered this exact indexed step |
| Waiting for your review | The engine invoked the executor's explicit action-review callback |
| Checking earlier effects | A valid resumed checkpoint requires fresh read-only reconciliation; the earlier mutation is not replayed |
| Observation checked | The navigator returned actual verified inspection results |
| Step checked | The executor/critic produced an accepted step outcome and the engine completed its checkpoint transition |
| Step not verified | The step was declined, returned unverified, or failed before acceptance |
| Interrupted · inspect activity | A currently executing step was interrupted; earlier known checked sibling rows are preserved |
| Earlier run · not rechecked | The cursor passed this position in an earlier run, but no current-run postcondition check is claimed |

A verified tool response is not automatically a completed goal. The existing critic postcondition rules remain unchanged. Navigator observations use a different state from checked action steps. The UI explicitly states that checks describe individual steps rather than completion of the entire request. There is no inferred aggregate completed badge or tool-count-to-step conversion.

Attempt counts increment only at actual indexed entry or reconciliation. Counts and app UUIDs survive valid same-process checkpoint continuation. They are scheduling metadata, not execution authority or current evidence. No progress is silently restored from a different process/session.

## Stop, failure, and callback scope

The engine's error wrapper changes only an in-flight current row, preserving accepted siblings. Cancellation maps that row to interrupted; other failures map it to unverified. An error during final synthesis does not undo the fact that individual step checks were accepted.

The Store integration is owned by the workspace reviewer: it fences callbacks by actual run revision and logical task ID, clears progress for fresh tasks/thread/context changes, and marks in-flight rows on Stop when the revoked engine callback is correctly rejected. Late callbacks cannot overwrite a replacement task. The root reviewer owns the activity-panel rendering.

Provider-sharing review inside an underlying dispatch may be presented by the Store's real review banner rather than a per-step review state. The projection does not infer a review from a delay or a role name.

## Tests added

`PlanStepProgressTests` drives the actual orchestrator with inert callbacks and checks:

1. Duplicate model IDs and titles keep distinct application UUIDs; explicit review transitions preserve checked siblings and planned successors.
2. Decline never dispatches or promotes a checked state, including attempted continuation of a declined plan.
3. An unverified action acknowledgment plus a VERIFIED narrative cannot promote a step.
4. Stop/resume preserves UUIDs and actual attempt counts, marks prior cursor entries as not rechecked, and performs a fresh read without replaying the interrupted mutation.
5. Navigator completion is labeled Observation checked rather than a completed user goal.

Existing checkpoint tests continue covering stale leases, changed goals/context, declined actions, cache limits, and fresh reconciliation. New Store-level late-callback and replacement-task coverage is owned by the workspace reviewer.

`swiftc -frontend -parse` passed for the new model, checkpoint, orchestrator, and scripted tests. No concurrent SwiftPM build was launched by this reviewer; integrated compilation and execution are owned by the coordinating reviewer. These tests use inert tools, not actual file mutations, model providers, OS permissions, or private source reads.

# Calendar creation: provider routing repair

The user's screenshot showed a Codex CLI conversation collecting a meeting title and duration, then claiming Calendar creation was unavailable. The UI symptom had a concrete routing cause: `AssistantStore.runSingleAgent` exposed Calendar write tools only for the embedded LiteRTLM backend and explicitly excluded Codex, Codex CLI, and Claude. Other configured backends also failed that gate. `runMultiAgent` separately filtered all Calendar write schemas out of its tool list.

## Implementation

- All configured single-agent planner routes receive the existing create/stage, commit, and rollback schemas when the user has selected a writable Calendar destination. The hosted Codex route's allow-list and feedback path now support these actions too.
- The delegated executor receives the same existing Calendar write schemas when that destination is selected. Planner capability context is added as app-owned system text while preserving the role prompt.
- New `CalendarPlannerSupport` accurately distinguishes a selected write destination from required setup. Without a destination it directs the user to Settings → Sources → Apple Calendar, permission/refresh if needed, and Calendar for event creation. It does not claim that the app fundamentally cannot create events.
- The model-facing destination is the opaque alias `selected`. The actual selected calendar ID/account/title stays in the local workflow and exact review. Tool feedback returns only an opaque review receipt and checked outcome; raw event/calendar identifiers are not needed by the model.
- Date/time context uses the current device clock and time zone rather than earlier transcript dates. The instructions preserve local requested time and require an explicit duration/end when missing. Requested invitees are not silently dropped: attendee invitations remain unsupported by these tools.
- Actual write authority remains unchanged: an explicitly selected writable calendar, exact review, one-use approval, bounded workflow, and independent readback. Selection changes stop the run and invalidate pending reviews. Setup is not permission or approval; no permission prompt or destination selection is triggered automatically.

## Verification

The real Store pipeline fixture is parameterized over all six configured backends. It stages an event through the actual workflow, exposes both existing reviews, checks zero stored events before commit approval, then checks exactly one create and one independent readback. A separate fixture follows the hosted Codex route; another exercises the actual Store multi-agent role pipeline and carries the stage's returned opaque review ID into commit. Setup-state and fixed-clock cases accompany existing mismatch, rollback, replay, revocation, and review-boundary tests.

Parser and scoped whitespace checks passed in this lane. Root owns integrated compilation, test results, signing, and live observation. These are synthetic transports; this lane did not create events, enumerate the user's calendars, request OS access, select a write destination, or send invitations on the user's machine.

## Remaining boundary

A real meeting can be saved only after the user completes Calendar setup and approves its exact details in Relay. A successful fake transport is not proof of a real EventKit save. Real Calendar readback and account-specific behavior require their own opt-in qualification. The existing two-review stage/commit interaction remains in place for this repair; it was not weakened for visual simplification.

### Integration checkpoint

The first targeted integration run passed the actual Store Calendar pipelines across all six configured backends, hosted Codex, and the delegated executor. The run found one separate native-schema parity mismatch: the app description had changed but the embedded LiteRTLM tool registry still carried its old description. The native registry description is now synchronized exactly; no assertion was relaxed. The final full run must include that correction.

A further regression fixture reproduces the screenshot's three-turn clarification flow: the original tomorrow-at-noon request, title/no-invitees clarification, then duration. It checks that every planner completion receives the original request, clarification history, current device-clock context and Calendar schemas, with zero writes during clarification and both exact reviews before one create/readback. Its dates are derived from the injected fixture clock/time zone; no real event is created.

### Context-capacity correction

The complete integration run exposed a real budget regression: always advertising unusable Calendar write schemas and a long capability paragraph reduced the embedded 24 KiB context's fresh-history capacity below the existing 6,000-byte requirement. The implementation now gates write schemas by actual destination readiness across every provider, while retaining a short truthful setup/clock context when unconfigured. Calendar descriptions and parameter text are compacted identically in both registries. No current tool observation, protocol pair, assertion, or context limit is truncated/relaxed. A selected-Calendar plus MCP-profile fixture now checks the actual native header and a full 4,396-byte fresh observation so readiness cannot hide a coexisting-capability regression. Root owns its measured result and final qualification.

The first budget-correction measurement still failed: unconfigured MCP retained 5,939 history bytes, unconfigured production retained 5,909, and selected Calendar plus native control and MCP retained only 4,353. These were integration regressions, not accepted baselines. The selected profile is checked explicitly; Calendar readiness is based on real destination selection, never request keywords.

The final correction also compacts the shared base prompt and redundant schema wording in the app and embedded native registry. It preserves tool names, fields, types, required arguments, numeric bounds, scope and dedicated-workflow restrictions, untrusted-data treatment, secure-field exclusions, fresh-ID requirements, exact reviews, and outcome/readback distinctions. The native schema text shrank by 1,121 bytes and the base prompt source text by 570 bytes relative to the measured failure. This is a projection of capacity recovery, not a substitute for the root's actual native-header measurement and full suite. No header accounting, 24 KiB limit, complete observation, or test expectation changed.

A subsequent focused run passed the unconfigured MCP and production observation-capacity cases, but measured 5,821 history bytes for selected Calendar/native control/MCP. It also caught eight security-description literal checks: `ASCII only` and `mode=windows` had been rephrased. Those exact guidance terms are restored in both registries without changing assertions. The final follow-up removes more redundant wording plus the optional Gmail URL example; authoritative tool instructions retain file-move preview/review, literal proofreading outputs/no edit authority, and the other scope/readback restrictions. Source is frozen for the root's complete qualification run. Earlier projected savings were insufficient; only measured passing results qualify the repair.

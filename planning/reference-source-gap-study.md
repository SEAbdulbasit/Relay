# Reference source study: improving Relay beyond three demo tasks

Reviewed 1 November 2026. This is source evidence and an implementation plan, not a claim of feature parity or product superiority.

## Provenance and limits

The local full checkout `/tmp/relay-reference-reference` is at `f064441a6d4309b7ae810de08e27b15e688f9a0b`, committed 27 October 2026 (14:14:57 -0700), “Update Sidekick model selection for 2.7 (#372)”. It is five days behind today's review date. No fetch was performed, so it is not established as current upstream HEAD. `/tmp/reference-public-audit` is a loose extracted-file directory without an independently verified commit; use it only as an inspection aid, not provenance. The findings below were cross-referenced to the full checkout's file locations.

The official GitHub commit history (upstream link removed) was opened, but the tool returned a cached page ending in July 2026, older than the local checkout. That response cannot validate freshness. Pinned source: reviewed commit (upstream link removed).

The installed Reference trial used a hosted ChatGPT action model, while Relay uses local Gemma 4 E2B. Copying orchestration patterns does not establish equivalent model ability. No personal-source analysis was run.

## What is worth learning from the implementation

| Source evidence in pinned Reference checkout | Relay evidence | Implementable improvement |
|---|---|---|
| `Driver/NativePermissionReadiness.swift`: readiness requires a fresh app-owned AX marker and a decoded screenshot; connection/list-apps success is insufficient. Denied vs unknown grants remain distinct. | `SettingsView.swift` uses `AXIsProcessTrusted`; `AgentDesktopBridge.swift:122–160` probes version/ABI/permissions, while `AccessibilityCheck.swift` provides a fixture check. Live trial showed an enabled macOS switch with an untrusted current Relay build. | Present separate Model, App control, and Screen observation capability states. Bind successful fixture evidence to app-build identity, helper ABI and grant changes. Invalidate on rebuild/relaunch/revocation; never promote unknown to ready from a list-apps result. |
| `Driver/NativeAppStateRetry.swift`: read-only capture failures get bounded 2/3/5-second grace; permission, action and protocol failures do not qualify. | `AgentDesktopBridge.swift:284–395` exposes bounded command execution and `retrySafe`, but this alone is not a task recovery policy. Browser failure currently stops on ambiguity. | Typed recovery: transient opening/no-window errors may re-observe; stale refs require a fresh snapshot; ambiguous browser targets require deterministic target resolution or a focused question. Never automatically repeat a mutation because capture failed afterward. |
| `Cloud/RunWatchdog.swift`: budgets count active time and exclude waiting for a user reply. | `AssistantStore.swift:245–264` uses a four-minute wall-clock run budget. Review time can therefore consume execution budget. | Inject a monotonic clock and track running vs awaiting-review time. Keep an absolute maximum lifetime as a separate limit. Test a long approval pause followed by a short action, cancellation during pause, clock changes and exhausted active budget. |
| `Notch Magic/SidekickConversationRun.swift:6–140`: task/generation-scoped event recording, duplicate-message receipts, in-flight substantive tool checks and completion invalidation when another provider leg starts. | `AssistantStore.swift` has generation gates, verifiedResults, interruption messages and no fabricated action policy; these are valuable existing protections. Completion checkpoints are partly prompt-driven (`:300–306`). | Add a typed task outcome ledger: each requested subgoal has pending/verified/failed/uncertain evidence. Generate normal final replies from that ledger so “query entered” cannot become “file found,” and a late stale completion cannot settle a new run. Preserve existing generation gates. |
| `Cloud/FrontierRun.swift`: connector read and action surfaces are narrowed, account identity is bound to the invocation, specialized completion evidence is checked. | Relay deliberately limits sources and high-impact actions in `ToolPolicy.swift` and `AssistantStore.swift:795–798`. | Add per-task capability manifests and explicit result validators rather than giving Gemma every tool on every turn. For browser tasks include only requested app/site scope. Future connectors must bind account identity and consent independently; broad cloud integrations are not an offline parity requirement. |
| `Notch Magic/SidekickContext.swift` and conversation run storage separate source context and recorded UI activity. | `ContextWindow.swift:5–61` abbreviates observations, retains complete tool pairs/current task and explicitly signals omitted history. | Preserve current safeguards; improve tool-specific observation shaping before truncation. Retain target identifiers, current query, selected tab/window, visible-state freshness and errors ahead of decorative AX text. If an essential field is omitted, label it unknown and re-observe narrowly. |

Paths in the first column are relative to `upstream project macOS` in the pinned checkout. These patterns should be reimplemented for Relay's local architecture, not copied wholesale.

## Prioritized delivery plan

### P0 — finish the existing reliability gap

1. Browser target resolution and honest readback. Treat a single web content surface as valid when Safari provides no explicit selected-tab attribute. For multiple surfaces require a unique selected relation or resolved requested URL/window; conflicting evidence remains an error. Tests: single-page absent selection, multiple tabs, conflicting selection, duplicate matching URL, inaccessible page, redirect, empty content and no heading. Qualify page title separately from heading. Parent's browser-fix work is addressing the immediate regression; rerun live before marking delivered.
2. Current-build permission recovery and fixture readiness. Test stale entry repair, revocation mid-task, helper mismatch and no screenshot access. Do not infer screen capability from Accessibility alone.
3. Evidence-first final answer. Finder should say the query was entered and whether a matching result was actually observed in the main reply, not only expanded Activity.

### P1 — fewer failed interactions

4. Implement bounded read-only app-state recovery with injected timing and typed failure classes. Tests must prove no automatic mutation retry after uncertain dispatch.
5. Suspend active-time budget while awaiting human approval. Test timeout accounting without real long sleeps.
6. Use a task outcome ledger and retain independently checked facts across partial failures. Test two-step success/failure, cancellation, late result, resumed task and contradictory model summary.
7. Reduce local model tool/schema load with task-scoped subsets. Benchmark exact same prompts, same local model/backend and controlled state; include missing-tool recovery so routing does not silently remove a necessary capability.

### P2 — experience and broader qualification

8. Show concise inline task progress, expandable evidence and a specific recovery control. Avoid exposing raw planner-role labels and broad readiness badges.
9. Maintain a disposable application fixture suite: form filling (Unicode/multiline), click/readback, disabled controls, scrolling, keyboard focus theft, stale ref, window closing and permission loss. Add controlled fresh-state versions of Calculator, Finder and public-page tasks.
10. Track success rate and outcome truthfulness separately across repeated runs. Compare hosted Reference and local Relay openly as different configurations; claim only results demonstrated by the fixture/real-app matrix. “Exceed Reference” should mean a measured target such as fewer unsupported success claims or reliable fully local completion on a defined suite, not general superiority from three tasks.

## Vercel agent-desktop boundary

Relay's bridge already validates ABI 6, snapshot-qualified refs, private snapshot storage and structured `retrySafe` disposition. Those are integration primitives, not an autonomous assistant. Its current installed version/schema and upstream source should be studied independently before expanding action coverage. Do not interpret a library's click/type support as evidence that Relay completes arbitrary workflows. The parallel agent-desktop source study should supply pinned upstream provenance and action-specific regression cases; this document does not claim an independent fresh upstream review of that library.

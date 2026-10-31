# Engineering breakdown — conversational autonomous Mac assistant

Planning authority: [revised PRD](product-requirements.md), amended by [current direction](product-direction.md) and the user's explicit instruction: **local models only; internet allowed for user-requested browser tasks**. The exact source is preserved; [original PRD](product-requirements-original.md) is historical. No implementation, stack validation or calendar estimate is implied.

## Architecture and product contract

One natural-language chat supports direct answers and autonomous tasks. The product-owned agent loop dynamically constructs plans, selects tools, observes effects, replans and verifies outcomes. Internal capability policies and reusable procedures are not user-selected templates or keyword routing. Preserve task constraints and verified progress across follow-ups, mid-task steering and recoverable failures.

Adapters expose files/search, supported artifacts, browser tools and Mac desktop observation/control. Prefer structured tools and accessibility before visual control. No unrestricted shell or simultaneous agents driving the same desktop. Native macOS shell technology, runtime/model/quantization, driver and hardware floor require evidence; LiteRT-LM and Cua Driver are candidates, not settled choices.

All inference remains local, including model-based verification/recovery and any later embeddings. Scoped user-requested browser/network actions and explicit setup/update downloads may use the internet. Keep those channels distinct in policy and observability. No opt-in hosted model or fallback. Conversation/task state and approved memory remain local; no cloud sync, telemetry or automatic upload implementation.

First-release memory is conversation context, active task state, explicit preferences and user-approved facts, with view/edit/delete. Folder indexing, broader knowledge graphs, learned procedures and cross-conversation continuity are later scope. Proactive/scheduled/overnight operation and mobile implementation are outside first release.

## Foundation — contracts and evaluation design

| ID | Task / owner | Dependencies | Acceptance evidence |
|---|---|---|---|
| D-01 | General task envelope / product | — | Representative questions, drafting, files, artifacts, browser and desktop requests documented as examples, not modes. Ordinary authorized steps vs consequential review and excluded capabilities defined. Users can phrase variations without selecting a workflow. |
| D-02 | Agent/tool/state contracts / platform | D-01 | Dynamic plan graph, constraints, unresolved requirements, tools/capabilities, scoped arguments, observations, evidence, review binding, steering revisions and cancellation schemas. Persist planned/requested/executed/verified/failed/uncertain states. |
| D-03 | Open-ended evaluation design / evaluation | D-01 | Independent task outcome truth, development vs held-out variations, scoring definitions and fault injection. Include direct answers, single/multi-tool, multi-app, ambiguous requests, follow-ups, steering and partial mutations. No inherited minimum task count presented as new PRD requirement. |
| D-04 | Unified native chat design + independent critique / design + critic | D-01, D-02 | Chat, attachments, readiness, task progress, expandable activity without hidden reasoning, steering, Stop, review, completion/artifact links, memory and recovery states. Critic checks actual proposal; blocking findings resolved. |
| D-05 | Native Mac shell feasibility / desktop | D-02 | Spike native lifecycle, files/permissions, accessibility, runtime/driver bridges, cancellation and packaging. Record implementation choice from evidence; no premature Swift/runtime commitment. |
| D-06 | Inference/network/data policy / platform + privacy | D-02 | Prohibit hosted inference; distinguish browser/tool egress from model calls. Local retention/deletion, secret exclusion, user-operated auth, default transient screenshots and diagnostic metadata rules explicit. No cloud account needed for assistant operation. |

## Phase 1 — General agent prototype

| ID | Task / owner | Dependencies | Acceptance evidence |
|---|---|---|---|
| G-01 | Local model adapter / model | D-02, D-03, D-06 | Validate text/image, tool definitions, structured responses, streaming, context bounds, capability detection, cancellation, timings, memory and actual quantization. Reject invalid arguments. Test no hosted call/fallback under errors or missing assets. |
| G-02 | Scoped file tools and synthetic target / tools + evaluation | D-02, D-03 | Search/read authorized files; deterministic synthetic local target supports basic actions/readback and faults. External file content cannot expand authority. No folder index required. |
| G-03 | Desktop adapter feasibility / integration | D-02, D-05 | Evaluate Cua Driver for window/control discovery, accessibility values, screenshots, clicks/text/scroll, foreground needs, stale targets, permission behavior and packaging/license. Publish capability limitations. |
| G-04 | Dynamic agent loop / platform + model | G-01, G-02, D-02 | Choose direct response or dynamic action plan based on conversation and tool capabilities, not keyword/template selection. Track dependencies, observations and unresolved requested outcomes; adapt plan/method after failure. Bound time, inference, steps and repeated-action loops. |
| G-05 | Action policy, Stop and verification / reliability | G-02, G-03, G-04 | Validate tool requests/scope/fresh target before dispatch; enforce review boundaries. Stop acknowledges ≤1 second and blocks new dispatch under races. Independent readback prevents model “done” becoming success. Report in-flight/uncertain effects and preserve partial outputs. |
| G-06 | Native chat prototype / desktop | D-04, D-05, G-04, G-05 | One composer for answers/actions, file attachments/references, visible readiness, concise progress, persistent Stop and outcome evidence/artifact links. Optional detailed plan/activity; never expose hidden model reasoning. |
| G-07 | Varied task prototype evaluation / evaluation | G-06 | Complete varied user-written tasks with different tool sequences and reasonable paraphrases without predefined workflow selection. Inject wrong “done,” stale target, malicious content, budget exhaustion and Stop. Record configuration and failures. |

**Exit:** A real general-agent prototype completes varied local tasks via dynamic planning and tool use. Synthetic fixtures supply evidence and fault control; they do not define the product identity. This feasibility exit does not claim full alpha release percentages.

## Phase 2 — Private alpha

| ID | Task / owner | Dependencies | Acceptance evidence |
|---|---|---|---|
| A-01 | Browser adapter and scoped live tasks / integration | G-04, G-05, D-06 | Observe/navigate/interact and research with local inference. Internet used only within user-requested task scope; disclose network dependencies and consequential submissions. Local fixtures and live test pages exercise navigation changes, login expiry, injection and stale controls. Network loss preserves partial work. |
| A-02 | Artifact creation/editing / tools | G-02, G-04, G-05 | Supported document/spreadsheet/data tools create useful local artifacts; check file opens, structure and requested contents, formulas/totals where applicable. Links open actual outputs; no narrative-only claim. |
| A-03 | Follow-up context and active steering / platform + UX | G-06 | Carry constraints across turns. Apply compatible user steering to active plan; reconcile in-flight effects before conflicting changes. Invalidate affected pending approvals and obsolete actions, preserve unaffected verified work. Necessary questions targeted; optional uncertainty does not halt independent work. |
| A-04 | Persistence, crash reconciliation and recovery / reliability | G-05, A-03 | Persist plan/request/execution/evidence distinctly. On resume/crash reobserve and reconcile effects, never auto-replay unfinished mutations. Distinguish observation vs action failures; change method after repeated failure; avoid duplicate creation/submission. |
| A-05 | Review boundaries and partial-result UX / design + platform | D-04, A-01 through A-04 | Routine authorized reversible steps proceed without per-action approval. Sending/publishing/final submission/destruction/access expansion require actual destination/payload review. Excluded purchases/security actions remain unavailable even with a review UI. Outcomes disclose completed/verified/pending/uncertain work. |
| A-06 | Local preference/fact memory / platform | A-03, D-06 | Conversation/task continuity and explicitly approved reusable preferences/facts can be inspected, edited and deleted. Sensitive incidental content is not silently stored as persistent memory. No indexing dependency. |
| A-07 | Security, network and isolation suite / reliability | A-01 through A-06 | External instructions cannot override user/policy or grant access. Browser egress cannot enable hosted inference. Check scoped destinations, redaction, user-operated auth, permission loss, file boundaries, no unrelated context leakage, and no hidden task-data telemetry/upload. Local tasks work disconnected after provisioning. |
| A-08 | Frozen alpha qualification / evaluation | A-07, D-03 | Held-out open-ended suite passes revised gates below by task category/configuration. Include cross-tool/app variations, ambiguity, steering, interruption, uncertain effects and network/auth failures. Counts, failures, evidence and reproduction steps recorded. |

**Exit:** Bounded but general conversation-driven delegation meets baseline reliability; no template selection or fixed procedure router is used as a substitute. Supported envelope and unsupported portions are honestly disclosed.

## Phase 3 — User beta

| ID | Task / owner | Dependencies | Acceptance evidence |
|---|---|---|---|
| B-01 | Guided onboarding/model management / desktop | A-08 | Hardware/memory check; visible model/component size/progress; separate inference/driver/OS permission/network/target readiness; simple real first task. Explicit downloads and offline import with integrity verification. No assistant cloud login or hosted setup dependency. |
| B-02 | Repeated delegation and effort study / product | A-08, B-01 | Measure repeat delegation, setup success, active user time saved, corrections and avoidable interventions against manual baselines. Improve failures from real task patterns. |
| B-03 | Hardware/model/compatibility matrix / evaluation | A-08 | Compare actual shipped model/quantization/runtime, hardware and app versions on identical held-out tasks. Larger local model or internal routing only where evidence justifies it. Publish limits and foreground needs. |
| B-04 | Local diagnostics and memory controls polish / platform + UX | A-06, A-07, B-02 | Inspectable local metadata/export/delete; no automatic upload. Memory correction/deletion and source provenance understandable. Opt-in future diagnostic sharing requires a separately reviewed implementation decision. |

**Exit:** Users repeatedly delegate useful work with measurable effort savings and acceptable intervention; onboarding and failure handling are comprehensible on supported configurations.

## Phase 4 — Public release

| ID | Task / owner | Dependencies | Acceptance evidence |
|---|---|---|---|
| R-01 | Mac installation/update/migration / desktop | Qualified beta | Signed/notarized packaging, driver/runtime distribution review, asset integrity, interrupted download/import/update recovery, local history/memory migration and permissions tested. Downloads remain explicit setup/update activity. |
| R-02 | Regression gates / evaluation | Qualified beta | Model/prompt/runtime/driver/tool/policy/app/OS changes run relevant frozen/held-out regressions. No hosted inference of any kind; scoped network policy, Stop, critical failure and stability tests block regressions. |
| R-03 | Compatibility/support/launch / product | R-01, R-02 | Demonstrate open-ended delegation across files/browser/apps, not expense workflows. Publish measured requirements, supported envelope, local-model vs internet distinction, review/Stop/recovery and retention guidance. |

## Proposed release gates — revised PRD §15

- At least **85% verified task completion** and **75% completion without avoidable intervention** on the release suite. Define unavoidable decisions, planned inputs and corrective intervention separately; report counts and denominators.
- **Zero observed false completion or unapproved consequential action**, with explicit malicious-input and partial-mutation coverage. Zero observed is a tested-suite criterion, not a guarantee of impossibility.
- Stop acknowledgment **within one second** and **no new action dispatch after Stop**, including races. An in-flight action may finish and must be reconciled.
- **No out-of-memory termination** on supported configurations. Set task-duration goals after measurements rather than inventing a threshold.
- Independent completion predicates: file exists/opens, artifact content/totals correct, intended target values saved, correct draft/conversation, research sources support claims. Do not use executor narration as an oracle.
- Hold out task variations; evaluate direct answers, drafting, single-tool, multi-tool, multi-app, follow-ups and steering. Generalization/paraphrase tests must defeat hardcoded keyword/template dispatch. Freeze sufficient coverage and task count based on envelope; revised PRD does not specify a minimum of 100.
- Report by task category, model, quantization/runtime, hardware and app version. Averages cannot hide critical failures. Track setup success, repeat delegation, effort saved, latency/memory and local-only inference as product/diagnostic measures.
- Remove superseded 90%/80% gates and blanket 99% critical-field target; task-specific correctness checks remain essential but revised source does not prescribe that percentage.

## Critical path and parallel ownership

**Contracts/evaluation → local inference + file/desktop adapters → dynamic loop + policy/Stop/oracle → unified chat + varied-task prototype → browser/artifacts + steering/persistence/review → held-out alpha → onboarding/repeat delegation → public distribution.**

Model, file/desktop spikes, evaluation fixtures, design and native-shell feasibility can proceed independently after contract agreement. Independent critic reviews an actual proposal, and designer resolves blocking findings. Agree plan/constraint revisions, target freshness, tool authorization, evidence hierarchy and review invalidation before parallel implementation.

## Decisions requiring evidence

| Decision | Working constraint | Closure |
|---|---|---|
| Connectivity | Settled: local models only; user-requested browser/network tasks and explicit provisioning/updates may use internet | D-06 policy tests |
| Native shell/language | Native Mac UX; choose from bridge/lifecycle/packaging feasibility | D-05 |
| Model/runtime/quantization | Local-only across all roles; no arbitrary fixed winner | G-01, A-08 |
| Driver and tools | Evaluate Cua Driver; prefer scoped structured tools where available | G-03, A-01, A-02 |
| Hardware/OS/app matrix | Publish passing measured combinations, not assumed minima | B-03 |
| First task corpus | Varied real user-written requests and held-out variations, not a single product workflow | D-01, D-03 |
| Memory/indexing | Explicit preferences/facts first release; folder index/project knowledge later | A-06; later scope decision |

## Revised PRD traceability

| Requirement | Tasks |
|---|---|
| CHAT-01 / CHAT-03 | G-06, A-01, A-02 |
| CHAT-02 / CHAT-04 / CHAT-05 | A-03, A-04, A-05 |
| CHAT-06 (P1) | Optional later voice input; no required prototype dependency |
| PLAN-01 / PLAN-02 | D-02, G-04, G-07 |
| PLAN-03 / PLAN-04 / PLAN-05 / PLAN-06 | G-04, G-05, A-03, A-04 |
| PLAN-07 (P1) | Later internal procedure reuse, always underneath open-ended chat |
| §9 tools/verification/recovery | G-02 through G-05, A-01, A-02, A-04 |
| §10 memory | A-06, B-04; indexing/project/cross-conversation later |
| §11 architecture/state | D-02, G-01, G-03 through G-05, A-04 |
| §12 inference / §14 hosted opt-in | G-01, D-06, A-07, authoritatively amended to no hosted inference |
| §13 permissions | G-05, A-05, A-07 |
| §14 privacy/network | D-06, A-01, A-06, A-07, B-04 |
| §15 evaluation / §16 release | D-03, G-07, A-08 and phase exits |

## Later extensions — not current implementation

Folder indexing/project context/learned procedures require an explicit scope decision after B-02, source-permission and retention contracts, local indexing feasibility and separate qualification. They must not delay first-release approved-fact memory.

Proactive suggestions, scheduling or overnight execution require a later user-started-task policy change, explicit opt-in/trigger/pause/delete design, budgets and separate tests. No implementation is authorized by inclusion here.

Possible iOS: define an iOS-specific use case after beta evidence and explicit scope decision; validate local models, lifecycle/memory/file/permission limits; decide practical shared schemas/policy/evidence/fixtures; implement native adapters and qualify separately. No Mac automation parity or mobile implementation in current release.

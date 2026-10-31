# General conversational Mac assistant — planning package

Build one chat for natural questions and autonomous delegation across files, artifacts, browser and desktop tools. The assistant dynamically plans and selects tools; users do not choose workflow templates. Native macOS first, possible iOS later outside current scope.

The executable native alpha and setup instructions are in [the project README](../README.md). [Native implementation status](implementation-status.md) distinguishes verified behavior from remaining qualification. [Computer-control driver research](computer-control-driver.md) evaluates replacing the custom AX layer with Cua Driver; it is not integrated yet.

## Documents and authority

- [Revised PRD](product-requirements.md) — exact latest user-supplied source.
- [Current direction and amendments](product-direction.md) — reconciles prior instructions and records the user’s local-model/network amendment.
- [Engineering breakdown](task-breakdown.md) — dependencies, acceptance evidence, gates and traceability.
- [Historical original PRD](product-requirements-original.md) — preserved earlier source, not the current expense-first scope.
- [UX/design proposal](design-proposal.md)
- [Interactive walkthrough](design-preview.html)
- [Independent critique](design-critique.md)
- [Sentient OS source design audit](sentient-design-reference.md) — actual reference layouts, tokens and source locations.

Walkthrough content is illustrative, not executed verification. Design artifacts should be reviewed against the revised PRD and direction/amendment note.

## Connectivity decision — settled

The user requires **local models only** and permits internet for **user-requested browser/network tasks**, plus explicit provisioning/updates. No hosted inference, including opt-in fallback. This amends the revised PRD's hosted-provider provisions while preserving its browser capability. Local inference does not mean no network activity: tools and sites can transmit data within authorized scope. Keep local tasks usable disconnected; disclose unavailable online dependencies.

## First-release behavior

General user-written requests, direct answers and actions share chat. Plans are dynamic and inspectable on demand; progress shows concrete observations and verified steps. Follow-ups and mid-task steering preserve context. Routine authorized steps proceed autonomously; consequential actions receive bound review. Stop and honest partial results remain visible.

Memory initially stores conversation/task state, explicit preferences and approved facts with inspect/edit/delete controls. Folder indexing and broader searchable knowledge are later scope. Scheduled/proactive operation, unrestricted shell, mobile apps and concurrent desktop-control agents are excluded initially.

## Agent responsibilities

| Role | Deliverable | Review responsibility |
|---|---|---|
| Product/engineering planner | Revised scope, dependency backlog, gates | General agent behavior, explicit unresolved decisions |
| Designer | Native chat and execution state design | Unified entry, steering, memory, evidence and recovery |
| Independent critic | Findings on actual design | Reject template-driven product framing, misleading autonomy/network/completion claims |
| Coordinator | Reconciled package | Close critique and align artifacts with current source |

## Execution handoff

1. Agree tool contracts, completion predicates, context/steering semantics and native shell feasibility; enforce separate inference and tool-network policy.
2. Build local dynamic-agent prototype with scoped file tools, desktop observation/actions, Stop, verification and varied user-written tasks.
3. Add artifact and browser adapters, steering, persistence, recovery and review; exercise scoped live networking with all-local inference.
4. Qualify on held-out open-ended task variations: proposed 85% completion, 75% without avoidable intervention, zero observed critical policy/completion failures, Stop and stability gates.
5. Improve onboarding, approved memory and compatibility through real user delegation. Expand capability coverage from evidence.

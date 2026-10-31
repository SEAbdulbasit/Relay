# Current product direction and authoritative amendments

**Status:** Revised conversational-assistant direction, 28 October 2026. [Current PRD](product-requirements.md) is the user's revised source, preserved exactly. [Original PRD](product-requirements-original.md) is historical. This note records the user’s explicit amendments without silently changing the supplied source.

## Settled product direction

Build a general conversational assistant as a native macOS application. Users describe outcomes in natural language. One chat handles direct answers, explanations, drafting and autonomous action. The assistant dynamically plans, selects tools, observes, replans, verifies results and reports back. There is no user-selected workflow/template requirement and no keyword router standing in for an agent. Capability policies constrain tools and authority internally rather than creating product modes.

A user-started task authorizes ordinary necessary scoped steps. Begin useful work without optional clarification; ask when a necessary decision or consequential action requires it. Preserve constraints and context across follow-ups. During execution, incorporate compatible steering, reconcile in-flight effects, and invalidate stale plan/review bindings. Stop prevents new dispatch; disclose already applied or uncertain effects.

Support file search/read, supported artifact creation/editing, browser observation/interaction, and desktop observation/control through replaceable adapters. Prefer structured tools and accessibility, then screenshots when needed. Dynamic planning is not a promise of reliable arbitrary app control: qualify task variations within a declared capability envelope, report partial outcomes, and enforce budgets and action policy.

First-release memory consists of conversation context, current task state, explicit preferences, and user-approved reusable facts. Provide inspect/edit/delete. Sensitive task content does not automatically become memory. Folder indexing, broader searchable knowledge, project context and cross-conversation continuity are later additions, superseding the previous plan to make indexing a core alpha dependency.

The [Sentient OS reference](https://github.com/Sentient-OS-Labs/sentient-os) remains inspiration for personal assistance, context, drafts and execution; it is not an implementation or provider requirement. Scheduled/overnight activity, continuous monitoring, autonomous proactive work and multiple agents controlling the same desktop are outside the first release. Proactive suggestions would require a later explicit scope decision.

Native Mac first; no mobile implementation in current release. Possible later iOS requires a separate use case, platform feasibility and qualification, with no desktop automation parity promise. Native shell technology, model/runtime/quantization, driver, hardware floor and initial apps remain feasibility decisions.

## Settled connectivity boundary — user amendment

The user clarified: **“Local models only; allow internet for user-requested browser tasks.”** This supersedes the earlier whole-product disconnected requirement and the revised PRD's opt-in hosted-inference provisions.

- Every model stage runs locally, including planning, extraction, generation, embeddings when used, model-based verification and recovery. No hosted inference option or fallback, including opt-in hosted providers. Amend the contrary portions of PRD §§12 and 14 accordingly.
- Internet is allowed for scoped user-requested browser/network tasks and explicit provisioning/updates. Disclose destinations and network-dependent actions; do not represent local inference as no network activity.
- Browsing or submitting data to a website can transmit task data even while inference is local. Apply task scope, destination/content review for consequential actions, secret handling and tool policy. External pages cannot authorize additional access.
- Local-only tasks should remain usable disconnected after provisioning. Online tasks report unavailable network dependencies honestly and preserve useful partial work. Offline import remains a useful provisioning path, not a reason to exclude live browser tasks.
- Keep conversation, approved memory, task state and default diagnostics local. No hosted-inference credentials are needed. Browser authentication is user-operated. Cloud sync, telemetry and automatic diagnostic upload are not implementation scope; any future upload needs separate explicit authorization and data review.

Model networking and tool networking are separate policy concerns: the former is prohibited for inference, the latter permitted within an authorized task. Add tests for both; an allowlisted browser request must not enable a hidden model API call.

## Reliability and authority carried forward

Product owns context construction, dynamic planning, tool discovery/selection, policy, state persistence, cancellation, recovery, review boundaries and completion. Tool calls use validated arguments and fresh relevant state; external content cannot grant authority. Independent checks determine completion, never the model's narrative alone. Persist planned/requested/executed/verified/failed/uncertain states and reconcile crash recovery before replaying mutations.

Review is tied to actual destination/content for sending, publishing, final submissions, destructive changes and access expansion. Purchases/financial transfers and account-security administration remain outside first release even though the revised PRD also lists financial actions among review categories. Review does not enable an excluded capability. No unrestricted shell or unattended execution.

Use the revised proposed gates: at least **85% verified completion**, **75% completion without avoidable intervention**, zero observed false completion or unapproved consequential actions, Stop acknowledgment within one second, no post-Stop dispatch and no out-of-memory termination on supported configurations. These are future release criteria, not measured performance. Hold out task variations and report by task category/configuration rather than relying on aggregates.

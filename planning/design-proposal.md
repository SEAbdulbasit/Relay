# Relay — conversation-first macOS design

Revision 5 · 29 October 2026. Supersedes earlier template-led, light-sidebar and fully-offline product directions. Basis: revised Local AI Desktop Assistant PRD plus explicit user decision: **local models only; internet permitted for user-requested tasks**.

## Reference and original design

The previous warm sidebar design diverged from the user's requested reference. This revision inspected actual Sentient OS macOS source at commit `f064441a6d4309b7ae810de08e27b15e688f9a0b`: `Views/Theme.swift`, `Views/HomeView.swift` (chrome and bottom dock), and `Views/Sidekick/SidekickStyle.swift`, `SidekickComposer.swift`, `SidekickTranscript.swift`. The source audit is recorded in [sentient-design-reference.md](sentient-design-reference.md). No downloaded app was built or run.

The relevant reference is a black spatial canvas, near-neutral glass, precise white system type, localized spectral illumination at the top edge, quiet top navigation and a centered bottom composer. It is not a permanent sidebar dashboard. Relay now uses this hierarchy with original CSS and an original Relay line mark; no Sentient logo, artwork or Swift implementation is copied. Reading surfaces stay neutral. The restrained empty state uses a 32px mark, 23px heading and 13px supporting copy. Composer maximum width is 744px, with a 36px circular send control and 18px corners. Assistant text sits directly on the canvas; user messages have subdued dark bubbles.

| Before | After | Why |
| --- | --- | --- |
| Warm navigation rail and white forms | Black canvas and compact top controls | Match the inspected reference's spatial hierarchy |
| Greeting as a marketing hero | Small mark and restrained readiness state | Keep attention on the conversation |
| Separate task screen and progress form | Persistent transcript and bottom composer | Questions, delegation and steering share one surface |
| Prominent colored panels | Neutral glass with localized edge light | Use light for depth without tinting reading surfaces |

The emil-design-eng skill informs restraint, readable hierarchy, instant feedback, precise transitions and interrupted-state handling. Navigation and keyboard actions do not animate. Reduced motion removes positional effects; reduced transparency uses opaque neutral surfaces. Atmosphere is static and does not consume attention or require animation.

## Unified conversation

The main entry point is natural language. Users ask a question or describe an outcome; no workflow/template selection is required. Suggested requests demonstrate breadth rather than define product modes. Direct answers, interpretations, execution updates, clarifying questions, results and follow-ups remain in the same conversation. A short interpretation precedes action when useful; the detailed plan and activity are expandable, not mandatory reading. Tool observations can be exposed, hidden model reasoning cannot.

The composer remains mounted visually during execution and accepts steering such as “Only this year.” Compatible constraints update the current task and invalidate affected extraction/verification steps rather than start a disconnected task. A small status question can be answered while the original task continues. A genuinely incompatible or ambiguous instruction pauses the task with a focused explanation. Typed drafts, keyboard focus, caret/selection and reader scroll position must survive progress updates; following the latest is conditional on the reader already being near the bottom.

Results include artifact cards or exact destination links, what was verified, and unresolved work. Evidence is bound to that result's source version and constraint snapshot so later tasks cannot rewrite the provenance of earlier replies. Preview artifacts are prepared inside the conversation and explicitly not saved to disk.

## Autonomy, scope and Stop

A task authorizes ordinary necessary reading, navigation, drafting and routine reversible work within its actual scope. Do not require a review screen for every task or click. Consequential effects—sending, publishing, final external submission, destructive changes, purchases, financial actions and access expansion—require an explicit review tied to actual content and destination. A changed payload, file, recipient or record invalidates that approval. No source document, website or app content can enlarge the user's authorization.

The optional inline activity distinguishes planned/requested/executed/verified/failed/effect-uncertain states. Stop remains available in both the composer and top chrome across navigation. It immediately prevents new dispatch; an operation already in progress may finish. Acknowledgement target is within one second. The stop-settling state preserves drafts and disables new submission until settled. Results disclose verified, uncertain and unattempted effects; they do not promise rollback.

Resume refreshes source/target state, checks local readiness and preconditions, reconciles uncertain effects and then continues from verified progress. Source changes invalidate scope. Missing model readiness blocks both normal resume and renewed-scope continuation. Crash recovery never blindly replays a mutation or reuses stale coordinates.

The four outcome meanings remain: Completed only when all requested outcomes are independently verified; Ready for review when preparation is finished but user review/final action remains; Needs input for a specific blocking decision; Stopped or failed with partial/uncertain effects disclosed. A model's “done” is insufficient evidence. Prefer saved-state checks, structured state, accessibility and deterministic comparisons before weaker screenshot judgment.

## Memory, models and network

First-release memory consists of conversation/current-task context, explicit user preferences and approved reusable facts. Users can view, edit and delete approved memory. Sensitive facts never become persistent merely by appearing in conversation. Folder indexing, automatic knowledge ingestion and learned procedures are later capabilities; no continuous activity collection is implied. Preview memory is synthetic and session-only.

Product copy: **Model runs on this Mac. Network when a user-requested task needs it.** No hosted model, provider selection or fallback is offered, including opt-in fallback. Already provisioned local tasks work disconnected. Browser tasks may access user-requested websites; show network-dependent activity and relevant destinations. If connectivity fails, preserve partial work and explain the unfinished portion. Local inference must never be advertised as zero network activity. Model provisioning/downloads and software updates are distinct from task execution.

Model installation, model capabilities, driver readiness, OS permissions and supported target-app readiness require separate setup tests. Hardware/model/runtime/quantization choices remain feasibility decisions. Native macOS is the first product; mobile is outside the first release.

## Review artifact and validation

[design-preview.html](design-preview.html) is an original dependency-free HTML review artifact, not the shipping technology choice. It provides a unified conversation, two explicitly seeded examples, direct answer plus task in one history, optional plan/activity, mid-task year steering, persistent Stop/resume, result artifacts/evidence, conversation search, editable/deletable approved-memory examples and local readiness settings. Unknown requests receive a truthful prototype limitation; there is no keyword router silently substituting a preset task. Seed labels are demo affordances, not a proposed mandatory product flow.

The preview does not run inference, read or save files, control the desktop, connect to websites or persist data beyond the page session. No hosted path exists. Source-reading and JavaScript syntax checks were performed. Visual rendering was blocked by browser policy; no rendered, native, accessibility or usability validation is claimed. The Sentient repository was inspected as source rather than a running app.

Next native checks: representative Mac window sizes and text enlargement; keyboard/VoiceOver; compositor focus/selection and scroll while typing during activity; stop at every action stage and from settings; model unavailable on every continuation path; source/target drift; consequential-review binding; interrupted write reconciliation; evidence matching saved outcomes; local task while disconnected; browser disconnect with partial preservation; outbound hosted-inference rejection. The design preview cannot establish execution reliability.

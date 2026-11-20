# Relay: a clearer place to do good work

**Implementation update:** the history ownership repair, inline-note draft recovery, recoverable Trash, and saved-result workflow are now implemented and qualified. See [current results and remaining boundaries](workflow-safety-2026-11-20.md). The audit below records the findings that led to this work.

Fresh design iteration following the reliability pass. Three independent agents audited workspace, Knowledge/settings, and onboarding/identity. The primary agent inspected the running app and coordinated the resulting native implementation. Existing optional design skills were not applied for this independent pass.

## What the audit found

Relay's useful distinction is the journey from a request to an inspected action and a lasting result. The interface still distributes attention across a feature showroom, chat controls, setup options, and technical activity. The problem is the hierarchy and the continuity of work across these surfaces.

The chosen direction is **Relay Workbench**: warm paper in Light, graphite in Night, mineral teal for identity and navigation, generous editorial introductions, compact working controls, and clear reading measures. Semantic success, warning, and failure retain their own meanings. A selected model is not necessarily connected; a tool check is not proof that the user's entire goal is complete.

## Implemented design slice

- **Home:** task-led introduction and concrete starts, with the composer remaining the primary place to express intent. Fictional feature tours leave the default working surface.
- **Working state:** central factual status and an explicit route to inspect Activity, using existing task and plan state. No invented progress percentages or success claims.
- **Conversation and composer:** quieter response controls, deliberate reading width, grouped optional actions, explicit app-work affordance, preserved Send/Stop and model selection.
- **Knowledge:** notes take priority over imported sources; a useful library overview derives from actual stored content. Reading and provenance receive more space and decorative graph counts receive less emphasis.
- **Onboarding:** a real local calculation becomes the first proof of value; scripted demonstrations become optional and clearly labeled. Setup retains its real provider, permission, and source controls.
- **Shared identity and Settings:** adaptive paper/graphite surfaces, mineral-teal affordances, a stronger title/eyebrow scale, and clearer Settings selection and page hierarchy. The duplicate manual background-cycle controls were removed from the suggestions section; Background preparation owns the remaining Prepare now/Stop controls, while Suggestions on Home retains its own visibility toggle.

Independent evidence and recommendations:

- [Workspace audit](design-audit-workspace-2026-11-20.md)
- [Knowledge and Settings audit](design-audit-knowledge-settings-2026-11-20.md)
- [Onboarding and identity audit](design-audit-onboarding-identity-2026-11-20.md)

## Gaps still worth filling

| Priority | Gap | Concrete next outcome |
| --- | --- | --- |
| 1 | Relaunch can duplicate the recent segment of an archived conversation because journal restoration has no explicit persisted thread owner. Live inspection plus source review establish a duplication path; message loss was not established. | Qualify an isolated append → restart regression, then persist journal-to-thread ownership. Do not merge conversations by title, text, recency, or a time-gap heuristic. See [history follow-up](design-history-followup-2026-11-20.md). |
| 1 | A task is still distributed across chat, Activity, review, and recovery. The new status strip improves visibility without introducing a persistent task model. | A durable task inspector with the original request, current step, pending decision, actual effects, and resumability; History can remain visible beside it at wide widths. Design the data contract before adding more panels. |
| 1 | Unsaved-note protection covers navigation, but quit/crash recovery remains outside the qualification. | Local draft recovery and deliberate window/app-close handling, with restored draft and source identity after relaunch. |
| 1 | Model selection, installed runtime, live connection, feature support, and permission remain separate facts across the app. | One shared capability/readiness presentation with a specific next action, reused by Home, onboarding, provider settings, source synthesis, and actions. Preserve per-provider authority and failure boundaries. |
| 1 | Physical and account-dependent reliability remains only partially qualified. | Actual login approval/login, sleep/wake/lid/power, live alternate-provider failure/recovery, and external-app multi-agent interruption/readback. The prior report records 78 skipped opt-in checks. |
| 2 | Review can compete with other dock messages and has limited evidence-reading room. | A dedicated readable decision surface with target, proposed effect, scope, evidence, and stable Decline/Approve controls. Keep approval authority unchanged. |
| 2 | Knowledge filtering and graph browsing do not yet form a complete research workflow. | Unified retrieval with source/result distinctions, relevant excerpts, indexing freshness, unresolved/stale links, and response-to-source navigation. |
| 2 | Accessibility and responsiveness need systematic runtime qualification. | Full keyboard and VoiceOver traversal, text scaling, Increase Contrast/Reduce Transparency/Reduce Motion, compact/short windows, long/localized strings, and RTL. Contrast tests alone do not establish accessibility. |
| 2 | Source setup remains spread across connectors, permissions, selection, indexing, and preparation. | A source lifecycle showing permission → selected scope → imported content → prepared/searchable state, with factual freshness and a precise recovery action. |
| 3 | New visual identity and terminology are not yet reconciled across the website, app-store assets, menu bar, Sidekick, and every specialist sheet. | A deliberate cross-surface pass after this native iteration is accepted and qualified. |
| 3 | Product value and performance lack a realistic repeatable acceptance set. | Timed first-success, first useful note/result, realistic large-vault retrieval, long-chat responsiveness, review comprehension, and successful return-to-work checks. Measure before claiming improvements. |

## Scope and verification

This iteration changes native presentation and local navigation affordances. It does not enable permissions, source scopes, provider accounts, login items, schedules, or new autonomous authority. Existing dirty checkout changes are preserved. Build, targeted regression checks, and live observations are recorded below after integration. These checks do not replace the remaining real OS/hardware/account qualification.

### Integrated checks

- Two targeted serial runs passed **58 tests in 9 suites**, including palette contrast in both appearances, onboarding calculator state, note navigation guards and exact destinations, task continuation authority, actual plan progress, background reliability, and design parity. Final targeted log: `/tmp/relay-design-regression-final-2026-11-20.log` (6.185 seconds after compilation).
- New mineral-teal text is included in the existing normal-text contrast check against all shared backgrounds in Light/Night. The old unused minimum-1000-point text measure expectation now checks the meaningful reading/composer nesting relationship.
- Cross-review found and corrected stale composer focus on the new Knowledge link, a retained text filter on Browse sources, missing selected collection state, false Completed labels on freely skippable setup steps, a potentially stale model-route footer, and calculator Return-key behavior. Live calculation through Return stayed on Welcome and returned **42**.
- Live inspection covered wide and compact/short windows, Light and Night, Home draft-only starts, actual route display, the saved synthetic note, Overview and real row-button roles, zero-results filtering and clear, editing and Save/Discard/Cancel on departure, and the response More menu (Reply / Quote / Regenerate). Cancel preserved the exact unsaved synthetic text; the saved note was restored unchanged afterward.
- Settings Automation exposes one manual preparation control under Background preparation. Source scopes, provider selection, permissions, schedules, and login item were not changed. Existing enabled suggestion/background preferences were preserved.
- A synthetic provider request using the existing Codex workspace performed a calculator call and returned **7 × 8 = 56**, with real Activity and the central planning status strip. No file/app data was requested. The run used the current single-agent mode, not a newly qualified live multi-agent scenario.
- Final live observations prompted finishing changes: readable two-column filters, correct singular/plural counts, brand tint on new menus, preserved sidebar choice on ordinary submission, a single Send affordance for populated drafts, window attachment in Actions, and optional calculation-evidence disclosure. These presentation/interaction refinements receive final compilation and focused runtime verification below.

Final build completed in **28.05 seconds** (`/tmp/relay-design-shipping-build-2026-11-20.log`); strict deep signature verification and whole-checkout whitespace checks passed. The final live bundle showed `54 sources · 1 note`, legible unbroken Preferences in the two-column filter grid, real note buttons, and the mineral-teal menu tint. A second actual calculator request returned **16 + 9 = 25** while History remained selected and central Planning/Stop/Inspect activity remained available during work. A populated draft exposed Send without the duplicate Run task affordance. Actions retained app-window attachment and all summary/drafting entries. The app was left open on the synthetic verification conversation in the user's original Light appearance. No production history records were deleted or merged.

The last inspection also exposed a conversation-relaunch duplication path. It is explicitly an outstanding P1, documented in [the history follow-up](design-history-followup-2026-11-20.md), rather than claimed fixed by this design iteration. Full VoiceOver traversal, text scaling/RTL, real pending external-app review at every short height, and OS/hardware/account gates remain unqualified. The previous 2,088-test full reliability run is historical evidence; this design iteration's current automated evidence is the 58-test targeted run and final signed compilation/live checks.

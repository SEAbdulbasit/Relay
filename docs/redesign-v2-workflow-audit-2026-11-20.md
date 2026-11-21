# Relay redesign v2 — workflow and information architecture audit

20 November 2026. Independent source audit; no app source, build, account, settings, or UI actions changed in this lane. This proposal is an interpretation of Relay's implementation and user request, not a claim to have inspected the Desktop references (the reference lane owns that inspection).

## Selected direction and implementation handoff

The independent sidebar-first proposal below was reconciled with the reference lane's direct Desktop study. The selected implementation uses an **open canvas with history hidden by default**, an optional approximately 240 pt sidebar, slim transparent chrome, a single-row composer, and a task-specific Activity inspector. This supersedes the always-visible 224 pt split-shell proposal below; retain the hierarchy, alignment, state, and consistency rules rather than treating the alternative dimensions as an implementation contract.

This lane subsequently implemented only `Sources/Relay/WorkspaceStartView.swift`: a centered 25 pt medium invitation, three plain draft suggestions in a horizontal layout with a vertical `ViewThatFits` fallback, and setup affordances only when needed. The model name/Knowledge/Brief callbacks remain in the initializer API for safe integration but have no duplicate idle UI. The real draft prompts are unchanged and never auto-send. The task strip is now one quiet line of truthful status, optional step detail, and Activity access without another border/card. Its accessibility identifier and action remain intact. `swiftc -frontend -parse` passed; root owns compilation, rendering, and interaction verification. No account/settings/source changes were made in this lane.

## The design problem is structural

The current implementation has reduced individual controls but retained three competing shells:

- A full-width 48 pt global header containing sidebar, app branding, Search, Brief, Knowledge, Settings, conditional access and Stop.
- An opaque 256 pt sidebar containing New chat, a History/Activity segmented control, an additional search field, an In this chat disclosure with count badge, grouped history, a thread count, Trash and another menu.
- A content surface with a marketing-style empty state, conversation, stacked notices/recovery/review cards, and a two-row composer.

The result can be uncluttered in an individual screenshot but still feel assembled. Global navigation lives both above and beside the content. The full-width header makes the two columns share an artificial roof while their content uses different alignments. The sidebar is disproportionately heavy beside short conversations. The colored edge light meets an opaque sidebar below a horizontal seam, exposing the layout's assembly. Removing labels at 980 pt changes the global navigation's shape rather than making the content adapt.

Specific source evidence:

- `MainView.swift`: `header`, `leftSidebar`, `historySidebarContent`, `conversationDock`, `taskRecoveryCard`, `reviewCard`, `activityPanel`.
- `WorkspaceStartView.swift`: a 40 pt two-line hero, monospaced eyebrow and numbered editorial rows, readiness status, duplicate Knowledge and Brief links.
- `RelayDesignSystem.swift`: reading width 780, composer width 900 capped again at 780 in MainView, content width 1080, several parallel type aliases and 28/30/34/38/56 pt control scales.
- `RelayWorkspaceBackdrop.swift`: backdrop is global, but the sidebar and numerous nested surfaces use independent opaque fills.

The previous pass addressed visible furniture. This pass should change the shell, hierarchy, and density before tuning the gradient again.

## One coherent direction: a quiet native conversation desk

The product's primary task is to express a request, inspect Relay's answer or proposed action, and continue. History and Knowledge support this task. Activity is evidence for a particular task. Setup is occasional maintenance. These roles should determine placement.

### Shell and navigation

Use a native split composition with a 224 pt sidebar and a flexible content column. Do not put a global header across both columns. The sidebar owns global destinations; the content has a small context bar. Keep the existing macOS window controls and platform behavior.

At the default 1180 × 820 window:

- Sidebar: 224 pt, 12 pt horizontal inset. A 48 pt top region accommodates platform chrome/brand. Small Relay mark and 13 pt semibold name, no second large brand in content.
- Global rows: New chat, Search, Knowledge, Morning Brief. 30 pt height, 14 pt regular system symbols in a consistent 18 pt icon column, 13 pt text. Only current destination receives a quiet 6 pt radius selection fill. No segmented control.
- Conversation section: 11 pt medium “Conversations” label, 12 pt top gap; grouped date headings optional only when needed. Thread rows 30 pt with 12.5 pt regular title and one-line truncation. Pin state is visible; rename/export/Trash remain contextual and accessible.
- Sidebar footer: one Settings row and a compact Trash entry/menu. Remove thread count: it adds no useful next action. Preserve the Trash recovery path.
- Content context bar: 44 pt high. Sidebar toggle and current thread title (or “New chat”) left; thread menu right. No repeated Relay logo, Knowledge, Brief or Settings here. Keep Stop visible while work/review is pending.
- Main content and composer use one 720 pt maximum width, with 28 pt outer padding. At narrower windows they shrink together. The conversation does not gain another independent margin system.
- Under 900 pt, sidebar becomes a disclosure/popover/drawer using the same rows. Never force a narrow transcript merely to preserve navigation. Avoid an always-visible icon rail plus a drawer: that creates another navigation tier.

Search can open the existing local command palette, which already matches thread titles, previews, message bodies and notes. Remove the permanent separate history-filter field. If an exhaustive filter is still necessary beyond the palette's bounded results, expose “Filter conversations” from the conversation heading/menu rather than occupying the idle sidebar permanently. Do not silently reduce search coverage; preserve the existing underlying query model.

The existing In this chat navigation should move to the thread menu (“Jump to message…”) or conversation search, retaining keyboard navigation and jump-to-original behavior. A count badge in the history list is the wrong level.

### New chat

Replace the marketing hero and numbered editorial rows with a single short invitation, e.g. “What would you like to do?” at 26 pt semibold, on one line where space allows. Add at most one short explanatory sentence, 13 pt secondary text. Place this near the upper-middle content area, not as a top-aligned landing page.

Below it, show three compact, lightly bounded or plain draft suggestions in one wrapping row: “Draft a reply”, “Understand a document”, “Work in an app”. Each is a real draft-filling action, not immediate execution. Keep the existing correct prompts/authorization behavior. Do not number them, add descriptive paragraphs, or simulate illustrative results.

The composer is the primary action, so the empty-state invitation must align with it. Provider readiness belongs beside the provider picker, not in a second status stack. When setup is incomplete, show one explicit “Choose a model” action at that location. Knowledge and Brief stay in navigation, without duplicate links below the hero. Proactive cards belong behind Brief or in one optional concise “Your brief is ready” row, not a competing Home deck.

### Transcript

- Same 720 pt measure as composer; 15 pt body, 5 pt line spacing, 22 pt between turns. Use text weight instead of a pile of small headings.
- Assistant content is plain prose. User messages may have one restrained neutral bubble; cap at 88% of the measure. No strong shadow.
- One consistent 26 pt message-action gutter, visible on hover/focus and exposed to accessibility. The already-verified Copy/Reply/Save actions, keyboard focus, context menu, saved-note Open/Export, and edit/regenerate gating remain.
- Group current-task evidence behind one disclosure aligned with its response. Never combine verified step status with inferred completion of the whole user request.
- Preserve code blocks, lists, reply references, jump-to-original, artifact reveal buttons and saved-note error/revalidation semantics. Long code scrolls horizontally inside its block; the whole transcript does not widen.

### Composer

Use a single consistent 16 pt continuous radius and a 1 pt low-contrast border; one elevation treatment only. Idle height approximately 98 pt including controls, growing with text to five lines. 14 pt horizontal and 12 pt vertical inset.

The writing field is 15 pt. Bottom control line: Add on the left, provider adjacent to it, dictation and Send/Stop on the right. This is one control group ordered by task, instead of a top-right mic/send pair and distant bottom-right provider. Primary Send/Stop is 30–32 pt; peer secondary icons 28 pt targets, 14 pt regular glyphs. Add labels/help and keyboard access remain. Keep Send and Stop distinct for active tasks; steering must not accidentally eliminate the ability to stop.

Selected image/window, reply, dictation and proofread feedback occupy a shared compact context region inside/attached to the composer rather than independent cards with different radii and borders. Keep selected-source name/removal, loading/cancel and meaningful errors visible. An empty attachment mode renders no UI.

### Atmosphere and palette

Use one warm-black or neutral-paper reading canvas, with one very quiet navigation surface. Let the top atmospheric color fade across both columns without a hard seam. Apply the gradient as a light source, not a background image; no continuous animation. Content text must remain on a quiet neutral field.

Use a neutral foreground for navigation and ordinary controls. A single restrained Relay teal can identify focus and the primary action, while amber/red/green remain semantic status colors. Do not color every icon. Do not pair multiple glows with every rounded surface. Contrast, reduced transparency, and reduced motion require solid/static fallbacks.

## Required task states

| State | Presentation | Existing behavior to preserve |
| --- | --- | --- |
| Idle/new chat | Invitation, three draft suggestions, composer | Draft is filled, not auto-submitted; readiness truthful |
| Active task | One 28–36 pt status row just above composer, current step optional, Activity link, persistent Stop | Real phase/current-step source, steering, cancellation authority |
| Activity inspection | Task-specific right inspector at ≥1250 pt; sheet/popover at smaller widths | Existing detailed plan, attempts, receipts, disclosures; no fake completion |
| Review pending | One clearly dominant review panel in content, with 120–340 pt evidence scrolling and exact Decline/Approve footer | Whole excerpt/action scope visible, approval gating and one-use review; no hiding structured/private evidence |
| Needs input | Short status plus focus action; user answers in composer | Latest required information retained; no unexplained disabled submit |
| Stopped/failed | One concise recovery strip with Inspect and Resume/Continue only when allowed | No statement that Stop undid changes; no automatic retries; activity retained |
| Attachment | Small source chip and removal; inline load/error | Exact selected source identity, cancellation, meaningful picker feedback |
| Saved response | Quiet Saved confirmation and Open/Export actions by the answer | Stable UUID note identity, re-read after modal, changed/missing-note errors |
| Persistent storage error | Readable local notice with recovery, not silently dismissed | No loss claims, journal/draft/recovery boundaries |

Activity should not replace all history navigation merely because `store.showActivity` becomes true. Keep global navigation stable; open the contextual inspector. In compact layouts only one auxiliary pane should open at a time.

## Implementation ownership and sequencing

The current `MainView.swift` owns almost every component and its private state. Do not assign different agents overlapping line ranges in that file. The root/integration owner should change the shell, header, sidebar, task inspector routing and composer layout together so hierarchy remains coherent.

Safe parallel lanes after contract selection:

1. **Root shell owner:** `MainView.swift`, `RelayApp.swift` only if needed for platform window chrome. Keep store and workflows untouched.
2. **Atmosphere/tokens owner:** `RelayWorkspaceBackdrop.swift`; preferably a new workspace-only `RelayWorkspaceStyle.swift` so global settings/onboarding/notch palette and shared mark geometry do not change accidentally. Coordinate names before root references them.
3. **Start/state components owner:** `WorkspaceStartView.swift`, receiving existing action closures and truthful readiness. May extract presentation-only task/recovery components to a new file with explicit inputs.
4. **Independent finish review:** inspect actual built states and widths, accessibility/focus and saved/Trash/review paths; no build/source mutation until findings are handed to root.

Do not expand the redesign into providers, Calendar authority, journal structure, model budget, file scope, source query mechanics, credentials or reset behavior. Those are checkpointed and qualified separately. The new design should make them easier to understand without rewriting them.

## Acceptance criteria

At 1180 × 820 and approximately 900 × 650: one navigation hierarchy; no global roof spanning mismatched columns; no Home marketing deck; composer and transcript align; user can identify the next action, stop active work and review exact evidence without searching. At rest, the conversation reads before chrome. In task states, required status and recovery do not disappear for the sake of minimalism. Inspect Light and Night visually, then keyboard and AX action access. Fix material issues from rendered evidence; compilation alone is not refinement.

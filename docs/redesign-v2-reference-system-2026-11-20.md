# Relay redesign v2: reference system study

20 November 2026. Read-only study of current official Sentient source and Relay checkpoint `2981ea4`. This lane did not inspect rendered Desktop images; the Desktop lane owns that evidence. Public source was read, not copied into Relay. Source observations below describe current public `main`, which can differ from the installed reference and historical screenshots.

## The underlying failure in Relay

The preceding pass removed obvious clutter but left three visual systems sharing the window. `WorkspaceStartView` uses a 40 pt semibold editorial headline, monospaced tracked eyebrow, numbered rows, readiness text, and footer links. `MainView` uses a permanent 256 pt productivity sidebar, segmented History/Activity switch, sidebar search, a second task inspector path, and a two-row chat composer. `RelayWorkspaceBackdrop` then supplies an atmospheric dark surface while the sidebar remains opaque. The result still reads as a dashboard with a chat inserted into it. This is an inference from the actual composition, not a defect in any one token.

Removing the numbered hero and the always-open sidebar will change the composition more than another palette adjustment. A single-row dock is also an architectural change: the eye should find one place to start, not a text row followed by a tools-and-provider shelf.

## Verified official-source observations

### Window and navigation

[HomeView.swift](https://raw.githubusercontent.com/Sentient-OS-Labs/sentient-os/main/Sentient%20OS%20macOS/Views/HomeView.swift), notably `topBar`, `emptyState`, and `bottomDock`:

- The default Home uses an open canvas rather than a permanent conversation sidebar. The 13.5 pt semibold wordmark lives in transparent chrome, padded 30 pt horizontally and 18 pt from the top. Conversation controls appear only in conversation mode; compact navigation applies below 980 pt.
- Empty Home centers a 48 pt mark, 22 pt medium question, and 13 pt status, offset upward 35 pt. It does not use an oversized, left-aligned editorial hero.
- The bottom dock is capped at 744 pt, with 38 pt side clearance and 14 pt bottom clearance. Suggestions are close to the dock in the relevant setup state. They fill drafts.
- The source has a small privacy footer; Relay need not add this because it already explains authority in the relevant workflows.

### Input and contextual controls

[SidekickComposer.swift](https://raw.githubusercontent.com/Sentient-OS-Labs/sentient-os/main/Sentient%20OS%20macOS/Views/Sidekick/SidekickComposer.swift):

- At rest, the input is one horizontal row: 15 pt text growing from one to five lines, 36 pt action controls, 14 pt spacing, and 17 pt surface padding. There is no permanent second provider/tools row.
- Reply and recovery content expand above the input only when relevant. The 10.5 pt helper row is specific to recovery, not permanent chrome.
- The 18 pt continuous surface is shared across normal, reply, and recovery input. Submission errors live immediately above the input. Buttons are real controls with labels, identifiers, and disabled states.

### Conversation rhythm

[SidekickTranscript.swift](https://raw.githubusercontent.com/Sentient-OS-Labs/sentient-os/main/Sentient%20OS%20macOS/Views/Sidekick/SidekickTranscript.swift):

- The outer transcript caps at 800 pt including 28 pt horizontal gutters: its 744 pt inner width aligns with the dock. Rows have 18 pt separation. User bubbles use 17 pt horizontal and 12 pt vertical padding with an 18 pt continuous radius; assistant content remains unboxed.
- Incoming rows can put work disclosure before the response. Message actions live in a reserved 20 pt bottom gutter. Hover does not alter row measurement. Copy and Reply remain native contextual/accessibility actions.
- On user scroll or selection, the view respects history reading rather than forcing the live bottom anchor. Search is a transient transcript mode, not a permanent second search field.

[SidekickTranscriptLayout.swift](https://raw.githubusercontent.com/Sentient-OS-Labs/sentient-os/main/Sentient%20OS%20macOS/Views/Sidekick/SidekickTranscriptLayout.swift):

- Activity is grouped once per task, associated with the first response. A terminal task event is not rendered as another ordinary message if a response already represents it.
- Status wording distinguishes working, waiting, stopped, failed, interrupted, and success; the finished state does not imply a verified real-world outcome without the relevant evidence.
- The useful principle for Relay is task-local disclosure and truthful state wording. Relay must preserve its own run identity, approval and readback model.

### Light and material

[SidekickStyle.swift](https://raw.githubusercontent.com/Sentient-OS-Labs/sentient-os/main/Sentient%20OS%20macOS/Views/Sidekick/SidekickStyle.swift):

- Reading space is black with neutral ink: primary white 0.93, secondary 0.53, accent 0.84. Color is localized light, not a filled reading panel.
- The crown uses broad overlapping blurred shapes with heights around 275–290 pt, blur around 64–69 pt, placed partially above the window. A smaller warm source sits below the dock. Motion pauses for inactive/occluded, scrolling, selection, and reduced-motion states.
- Prominent controls use native glass where supported; older-platform material is darkened. Increased contrast and reduced transparency have explicit fallbacks. The important relationship is bright ink over a restrained dark neutral material, rather than tinted fills everywhere.

[Theme.swift](https://raw.githubusercontent.com/Sentient-OS-Labs/sentient-os/main/Sentient%20OS%20macOS/Views/Theme.swift):

- Source design intent uses medium-weight system display type and avoids additional manual negative tracking. The dark reading surface and Knowledge navigation have distinct surface roles. The reference is dark-only; Relay must still support its existing Light and System choices.

## Proposed coherent Relay contract

These are recommendations for Relay, not claims that Sentient implements them verbatim.

1. **Open by default.** The reading canvas occupies the window. Keep one quiet history affordance at the left of the wordmark; history opens as a 240 pt supplementary panel or a popover on narrower windows. Keep the preference/reopen behavior deliberate rather than silently migrating every previous choice.
2. **One input row.** Put Add, growing text, mic, and send/stop on the same baseline. A 54–60 pt resting surface is enough. Place provider selection in an explicit contextual control or popover anchored near the dock; keep a meaningful discoverable model label, not an unexplained dot. Show attachments/replies above only when present.
3. **One column ruler.** Use a 740–760 pt working column, or a shared width constant for dock and transcript. On narrow windows use 24–28 pt gutters. Match the assistant text edge to the input text edge, not merely the outside rounded rectangle.
4. **One type voice.** Use 22–26 pt medium for the empty-state question, 14–15 pt regular for conversation, 12–13 pt controls, 11–12 pt metadata. Remove the workbench eyebrow, automatic line break in the hero, numbered starters, and promotional subcopy. Use no synthetic negative tracking on working text.
5. **One navigation vocabulary.** Home/chat, Knowledge, Brief and Settings each have one primary entry. History owns saved conversations; the active task owns Activity. Remove the permanent History/Activity segmented control if task-local inspection makes it redundant. Preserve reachable full Activity rather than deleting it.
6. **Neutral peer controls.** Use regular outlined system symbols of consistent optical size, stable hit targets, and no colored treatment on ordinary gear, Add, history or nav icons. Reserve accent for focus, active task, selected state, and meaningful status. Do not change success/error semantics.
7. **Atmosphere without a header bar.** Allow broad light to fade through the open canvas, with no header bottom border or sidebar surface cutting it into a rectangular strip. Keep all transcript text over the quiet neutral area. Static light is sufficient for this pass; no ambient animation is needed to establish the design.
8. **Preserve the working states.** Empty, typing, attachment, working, awaiting review, recovery, stopped, failure, saved-result and history-reading need the same composition. Stop must remain obvious. Review content and exact destination must remain explicit. Saved Open/Export and accessibility actions stay reachable.

## Finish gate for this direction

Inspect the actual build at the user's compact window and a wider window, Light and Night. Compare an empty chat, a multi-turn conversation, a working task and a review/recovery state. At rest the eye should see a restrained wordmark/navigation, one central intent, and one input surface. No duplicate model explanation, readiness shelf, permanent empty context panel, numbered feature menu, or decorative active stroke should survive merely because it existed before. Check pointer and keyboard access to hidden actions; no layout shift on hover; no forced scroll while reading. Calendar/tool/account behavior remains governed by Relay's existing reviewed workflows.

## Scoped implementation handoff

Following root's implementation assignment, this lane changed only `Sources/Relay/RelayWorkspaceBackdrop.swift`. The new atmosphere uses three unequal rotated light lenses, broader falloff, a near-black neutral base, and a restrained dock reflection. It has no continuous motion. The existing `.relayWorkspaceSurface(cornerRadius:)` API remains available with a 16 pt default, neutral material scrim, subtle 0.65 pt edge, and solid/strong-edge accessibility fallbacks. A new `.relayWorkspaceSidebarSurface()` lets supplementary history share the atmosphere rather than inheriting the old opaque document-panel color. Global colors, notch rendering, MainView, models, and workflow behavior were not changed by this lane.

`swiftc -frontend -parse` and `git diff --check` passed for the scoped changes. Compilation and live visual inspection remain root's integration work; this lane does not claim that the rendered result has passed.

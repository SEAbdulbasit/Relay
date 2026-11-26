# Workspace, Knowledge, Brief and first-run design audit

21 November 2026. Read-only source review by a separate audit agent. No app code, account state, permissions, notes or preferences were changed. No builds, tests or computer-use actions were performed in this lane. Native observations attributed to root below are distinct from this lane's source inspection.

## Prioritized findings

### P2 — Command search describes navigation that no longer exists

`Sources/Relay/MainView.swift:3390` labels the command **Toggle Left Sidebar**; line 3391 explains it as **Show or hide the History and Activity sidebar**. The current sidebar is History only and Activity is a separate task inspector. Root independently rendered this stale copy in the native command palette. This is a confirmed wayfinding defect, not a typography preference. Rename the command to Show/Hide history or Toggle history and describe History accurately, preserving `action.toggleSidebar`, its shortcut and callback. The native Task menu at `Sources/Relay/RelayApp.swift:104` still says Toggle Sidebar; harmonize that label too. The source section comment at MainView line 1495 is also obsolete, though that comment is not a UI defect.

The same stale-place problem occurs in Automation: `Sources/Relay/SettingsView.swift:1138` says **Suggestions on Home**. Root rendered this label in native Settings without toggling it or preparing anything. Current Home mounts only the introduction, composer and `WorkspaceDraftSuggestions` (`MainView.swift:230`); prepared follow-ups live in `ProactiveHomeDeckView`, now mounted in Morning Brief (`MorningBriefView.swift:1372`). Rename the section and supporting place references around the actual Morning Brief destination while preserving the existing suggestion/preparation bindings. This is a root-native-confirmed and source-confirmed P2 wayfinding defect alongside the command-palette copy.

### P2 — Standalone editor/search/inspector titles still use section-heading styling

The 640×480 writing-style editor uses `.relayHeadline` (14.5 pt) at `Sources/Relay/KnowledgeView.swift:1057`; its neighboring 640×500 sharing sheet already uses the 24 pt page-title token at line 1002. In MainView, the 600×560 Activity inspector title at line 1779 uses 13.5 pt `.relayBodyStrong`, and the 430 pt conversation-search sheet title at line 3202 uses 14.5 pt `.relayHeadline`. The quote-selection dialog at `Sources/Relay/ConversationReplyView.swift:75` has the same section-size title. These independently presented surfaces have no defined shared modal hierarchy.

Use an explicit compact-modal title role (for example 17 pt medium) for small search/quote/Activity surfaces. The larger writing-style editor can use the existing 24 pt standalone-page role, consistent with Share and Voice. Preserve complete disclosure/review text and editor byte limits. Do not impose 24 pt titles on tiny popovers merely to make all numeric sizes identical.

### P2 — Model-choice popover is a distinctly smaller control vocabulary

`WorkspaceModelOptions` at `Sources/Relay/MainView.swift:2098–2141` uses 10.5 pt symbols and 11.5 pt labels, with only six points of vertical row padding. The resulting ordinary selection rows are approximately 26 pt rather than the established 32 pt peer targets. The multi-agent switch uses the same small labels. This is a reachable, frequently used popover, unlike the intentionally compact hardware notch.

Keep its 250 pt width and actual provider handlers; use approximately 13 pt readable row labels, 14 pt regular symbols and a 32 pt minimum row height. Check long installed-model names without selecting or switching providers. Root subsequently rendered the native popover at wide width: readable with no observed overflow, but smaller/bolder labels and a lighter system-gray bubble visibly differ from Home's controls. No provider selection or toggle occurred. This is a coherence issue, not a claimed readability failure; this lane did not render it independently.

### P2 — Non-notch dismissal and editing targets retain inconsistent miniature sizes

The command-palette Close control is 28 pt with a 10.5 pt glyph at `Sources/Relay/MainView.swift:3494`; quote-selection Close is 28 pt at `Sources/Relay/ConversationReplyView.swift:77`; the workspace Cancel reply control is 24 pt with a 9.5 pt glyph at line 44 of that file; and the plan-step Remove control remains 24×24 at `Sources/Relay/MorningBriefView.swift:673`. These are actionable controls, not metadata. Root rendered the palette and found it readable; its smaller Close control is a consistency/target-size issue, not a claimed legibility blocker.

Use the 32 pt target/14 pt regular-symbol vocabulary for main-window/dialog controls. Reply chips also serve the hardware notch through `obsidianStyle`; preserve a compact notch branch instead of globally enlarging that chip and invalidating its hardware geometry. Keep named accessibility actions and disabled states.

### P3 — Legacy typography and empty-state decoration remain a secondary cleanup

`Sources/Relay/RelayDesignSystem.swift:590–595` still defines legacy 13.5/12.5/11.5/10.5 pt body/callout/caption/micro tokens alongside the new 13/12 pt page roles at lines 1940–1944. The command-palette row symbols at MainView line 3527 are 12 pt semibold, visibly heavier than the regular outline peers (root-rendered observation). Empty History and Activity use decorative blue badge tiles at MainView lines 1727 and 1886. These are lower priority than misleading navigation or inconsistent modal roles. Prefer replacing the remaining reachable uses locally; avoid a blind global font substitution that changes the notch's fitted layout.

## Surface coverage and native verification matrix

| Surface/state reviewed in source | Coverage and next safe native check |
| --- | --- |
| Home, composer, historical conversation, attachments/replies, saved responses | Current 15 pt reading/input, neutral attachment menus and 720 pt shared alignment are coherent. Show an unsent attachment/reply and cancel it; verify saved Open/Export access without editing/exporting user data. |
| Model-choice popover | Root rendered it without selecting a provider or changing multi-agent configuration; readable, no wide-width overflow observed. Check a long local-model label at compact width if later available. |
| Command palette and conversation search | Root rendered palette; stale navigation copy confirmed. Check empty/results/no-results, keyboard focus and close. Conversation search remains source-only in this lane. |
| Activity idle/running/stopped | Header's own Stop and Close remain wired. Check inspector and recovery using existing inert verification history or synthetic fixtures; do not start an external action just to obtain a screenshot. |
| Exact action review | `MainView.swift:1947–1991` retains readable scroll bounds, reason/evidence, explicit decline/approval, disabled approval gating and whole-excerpt disclosure. No approval-state rendering or boundary qualification was performed by this lane. Use inert review fixtures, never grant or approve an account action for visual QA. |
| Knowledge library, reader, overview | Current toolbar/page/reader typography mostly shares the page system. No new structural defect established from source. Native compact-width checks remain with root. |
| Knowledge sharing and writing-style sheets | Share title already mapped; writing-style title drift above. Inspect without activating sharing, saving changes, or replacing the snapshot. Monospaced byte counts/editor content are appropriate exceptions. |
| Brief cards and editable plans | Recently added vertical Goal/Step fields retain original bindings. Header/action-row layout and semantic current/unchecked states are coherent. Target-size issue for Remove is noted above. Do not Prepare, Run, Dismiss, Snooze or edit a real card during read-only review. |
| Onboarding welcome/model/access/privacy/ready | Reviewed source and scroll/pinned-footer structure. The welcome retains larger 32/40 pt introduction type and calculator's 32 pt monospaced checked result; larger introduction/result roles are defensible. Its legacy uppercase monospaced eyebrows remain a consistency candidate, not a demonstrated clipping defect. First-run/error/unsupported states were not rendered; use an inert fixture/profile rather than resetting the user's onboarding. |
| Notch collapsed/expanded/request/reply/review/status | Reviewed `SidekickNotchOverlay.swift`, reply-chip uses and `NotchVisualDesign.swift`. 13–14.5 pt text and 22–26 pt hardware-fitted controls are purposeful exceptions. Preserve the neutral black shell, semantic status colors, bezel silhouette, safe hit zones and existing review authority. Multi-display/hardware/review states were not live-qualified by this lane. |

## Reachability caution

MainView still contains old `homeFeatureShowcaseDeck`, `ComposerActionPillButton`, `SidebarTurnRow` and showcase implementations with legacy styling. Current references do not mount the old Home deck in the new empty canvas. Their many old 8.5–12 pt decorative values must not be reported as visible defects without establishing a reachable call site. This review intentionally prioritizes mounted model/search/editor/recovery surfaces.

No P1 design blocker was established. This is a prioritized audit, not a claim that every page or state has been rendered or that the design has passed a universal finish gate.

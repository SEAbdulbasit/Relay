# Relay design audit — 21 November 2026

Relay is not yet consistent across its full interface. The main page foundation is substantially more unified, but compact editors, embedded Settings sections and secondary dialogs retain several earlier design vocabularies. Three parallel audit agents reviewed Settings, workspace/pages, and small dialogs; the primary agent inspected reachable native surfaces. This audit made no application source changes.

## Findings and repair order

| Priority | Finding | Evidence | Recommended correction |
| --- | --- | --- | --- |
| P1 | Destructive button labels lack contrast in Night | `UninstallAndResetCoordinator.swift:583` uses white over Night coral `#F87171`: **2.77:1**. Factory Reset and Clean Uninstall previews corroborate the pairing. Light's pairing is 5.48:1. | Choose accessible ink/fill in each appearance, including hover and pressed states. Bring the danger style into the shared button geometry and verify keyboard focus. Preserve confirmation and execution behavior. |
| P1 | Clean Uninstall hides part of its exclusion statement | Native 520 pt confirmation truncates the sentence at `UninstallAndResetCoordinator.swift:812–814`, hiding “never modified.” | Let the complete statement wrap and the body grow or scroll. Preserve all scope wording and safeguards. |
| P2 | Dialog hierarchy and controls vary by surface | Note Trash uses 28 pt title/plain canvas/native Done; Conversation Trash uses 24 pt/shared backdrop/styled Done. Writing-style editor uses 14.5 pt while its sharing sibling uses 24 pt. Capsule danger buttons sit beside rounded Cancel. | Define deliberate roles: approximately 17 pt compact-modal titles, 24 pt full utility titles, 14 pt embedded section titles. Reuse header/action components and spacing. Do not apply page titles indiscriminately to every popup. |
| P2 | Decorative icon tiles remain throughout secondary pages | Provider setup, automation, updates, export, sharing and image inspection retain large blue/purple/green/gold filled tiles alongside the new neutral symbol treatment. Automation and sharing are native-confirmed examples; provider inventory is source-reviewed. | Use the shared regular-symbol size and neutral section treatment. Retain color for meaningful readiness, warning, error and destructive states, and retain genuine hardware illustrations. |
| P2 | Compact Settings headers crowd their text | Native on-device catalogue header wraps and truncates its capability badge beside Import. Sources' Add files/Add folder actions wrap to two lines; the calendar scope explanation is squeezed beside controls. | Reflow actions below explanations at narrow widths. Keep capability and permission qualifiers fully readable. |
| P2 | Navigation copy describes the previous layout | Native command palette says “History and Activity sidebar,” although Activity is a separate inspector. Automation says “Suggestions on Home,” although prepared suggestions now live in Morning Brief. | Harmonize visible labels and supporting descriptions with current destinations; preserve identifiers, bindings and shortcuts. |
| P2 | Popover/control scale differs from page scale | Native model picker is readable without observed overflow, but uses smaller, bolder labels and a lighter bubble than Home. Source review finds some 24–28 pt dismissal/edit targets alongside 32 pt shared targets. | Establish a compact-control variant with consistent label, symbol, row and target metrics. Respect the deliberately smaller hardware-notch interface. |
| P3 | Remaining legacy typography and nested panels add visual noise | Older 13.5/12.5/11.5/10.5 pt roles coexist with the new page scale; some embedded forms retain multiple panel layers. | Consolidate equivalent roles and remove redundant nesting after the defects above. Preserve monospaced code/Markdown and intentional hero typography. |

Source filenames above are under `Sources/Relay/`. Exact references and surface inventories are in the lane reports below.

## Coverage and limits

| Area | Current audit evidence |
| --- | --- |
| Home, navigation, command palette, model picker | Native inspection of Home and popovers; workspace/chat/inspector source review. Home returned to an empty composer with History hidden after inspection. |
| All nine Settings destinations | General, AI Models, Sidekick Shortcuts, Sources, Knowledge, Automation, Permissions, and System & Data were newly rendered; Magic Reply was inspected through native accessibility state. No provider, toggle, shortcut, permission, or account changes. |
| Knowledge and Morning Brief | Source inventory of library, reader, overview, Brief, plans and related controls. Native Knowledge navigation and its reachable small dialogs were inspected. Not every populated reader/Brief state was freshly rendered. |
| Small dialogs newly rendered | Voice Input idle; empty Note Trash and Conversation Trash; empty writing-style editor; Knowledge Share; portable archive creation with zero selected notes; initial Factory Reset and Clean Uninstall confirmation previews. All were closed/cancelled without data actions. |
| Conditional/operational surfaces | Source-reviewed recovery, summary-ready, image-answer, action-review, onboarding, update, uninstall-progress, and provider-specific setup states. These are **not** claimed as freshly rendered or passed. Native file panels/alerts remain platform-controlled exceptions. |
| Appearance and dimensions | Current native pass used Night. Contrast analysis covers Light and Night fills. A fresh Light pass and systematic minimum/wide-window matrix remain part of repair verification. |

Two source-derived width concerns remain **verification targets**, not confirmed visual defects: the Custom Responses preset/reasoning row and the ready summary reader's four-action footer. Image Inspection's fixed 540×640 sheet also needs a minimum-window check. Existing data or preferences were not altered to manufacture these states.

## Suggested implementation sequence

1. Fix destructive contrast and uninstall disclosure wrapping; add a focused contrast regression covering inverse labels on semantic fills.
2. Introduce shared compact-modal headers, standard header actions and spacing; apply them to Trash, recovery, writing, sharing, archive, search and inspector surfaces according to their roles.
3. Normalize embedded section icons and remove redundant panel layers across Settings and utilities.
4. Reflow crowded headers and narrow action rows; then check the source-only width risks in rendered states.
5. Correct stale destination copy and align the model picker/control metrics.
6. Verify Light/Night, minimum/wide windows, keyboard focus and applicable empty/loading/error/populated states. Keep native alerts/file panels and hardware-specific controls intentional exceptions.

No build or test suite was run for this documentation-only audit. Earlier redesign test results do not establish that these newly identified visual issues pass. The audit is not a universal finish-gate approval.

## Detailed agent reports

- [Settings and embedded pages](design-audit-v4-settings-2026-11-21.md)
- [Small dialogs and editors](design-audit-v4-small-dialogs-2026-11-21.md)
- [Workspace, Knowledge, Brief and first run](design-audit-v4-workspace-2026-11-21.md)

# Small dialogs and editor design audit

21 November 2026. Read-only source audit. No application source edits, build, account read, permission change, UI action, draft modification, export, sharing or destructive operation was performed in this lane. Root owns native inspection. Findings below distinguish source-confirmed facts from layout risks requiring rendering.

The current shared page vocabulary is ink/porcelain and restrained teal, regular 14 pt peer symbols on 32 pt targets, 13 pt form text, 12 pt supporting text, 15 pt reading text, 8 pt action-button radii and 12 pt panels. **Hierarchy should have variants:** 24 pt full utility/page titles, approximately 17 pt compact-modal titles, and 14 pt embedded section titles. Native macOS alerts, file panels and intentionally monospaced Markdown/code fields should retain their appropriate platform/content treatment.

## Prioritized findings

### P1 — Enabled destructive buttons have insufficient text contrast in Night

`UninstallAndResetCoordinator.swift:578–605` defines `RelayDangerButtonStyle`. The normal enabled label is white and its background is `RelayColors.accentCoral`; Night's exact color is `(248,113,113)` at `RelayDesignSystem.swift:426–428`.

Using the sRGB relative-luminance formula, white on this opaque background is **2.766:1**, below the 4.5:1 requirement for its normal 12.5 pt label. This normal-state result is independent of the containing canvas. The Light normal-state ratio is 5.475:1. Assuming the current canvas under the translucent background, Night hover/pressed are approximately 3.298/3.971:1; Light pressed is approximately 4.213:1. These latter values depend on the actual underlying surface, but the opaque Night failure does not.

This custom danger style also retains capsule geometry while primary/secondary actions use an 8 pt rectangle, and does not implement the explicit focus overlay used by those shared styles. That focus difference is a source observation; actual keyboard-focus visibility was not tested. Preserve the destructive color meaning and confirmation behavior; use an accessible label/fill pairing and the shared control/focus vocabulary. A follow-up contrast test should cover inverse button labels in normal/hover/pressed states, not just colored text on page surfaces. No enabled destructive button was clicked or rendered in this lane.

### P1 — Uninstall confirmation truncates the exclusion scope

Root rendered the actual 520 pt Clean Uninstall confirmation preview and observed the exclusion sentence at `UninstallAndResetCoordinator.swift:812–814` truncating to one line with an ellipsis, hiding the decisive “never modified” clause. The full source copy is: “Your personal folders, Apple Notes/Mail/Messages, ~/.codex, and ~/.claude are never modified.” The `Text` has no vertical fixed-size/wrapping accommodation in its confirmation container.

This is a **native-confirmed deletion-scope clarity defect**, not a speculative spacing issue. Allow the complete sentence to wrap (for example, vertical fixed sizing with sufficient container growth or a scrollable confirmation body), preserving the full exclusion copy and execution safeguards. Root only opened and cancelled the preview; no erase/uninstall action or checkbox change was performed.

### P2 — The smaller-surface title hierarchy and section symbols still come from several design generations

- `NoteTrashSheet.swift:14` and `KnowledgeDraftRecoverySheet.swift:30` use the **28 pt** `relayWorkbenchTitle`; note recovery/Trash are larger than the new 24 pt full-page titles. Their Done/Later controls (`:16`/`:32`) are unstyled native buttons beside shared styled actions. Choose a consistent compact-modal hierarchy and header actions rather than applying a large editorial title.
- `VaultNoteEditor.swift:42`, archive create/open sheets in `PortableKnowledgeSharingView.swift:65,210`, and `ConsolidationReviewView.swift:25` use the older **16 pt** `relayTitle`. `ConversationReplyView.swift:75` uses **14.5 pt** `relayHeadline` for “Quote a message.” These should be assessed together as compact-modal headings, approximately 17 pt, rather than automatically promoted to 24 pt.
- `ImageInspectionView.swift:24–37` retains a **38 pt blue icon tile**, a 19 pt title and 28 pt close target; it also uses blue tint at `:196`. This full image/window utility sheet visibly has a different header recipe in source from Voice Input. Use the full-utility header variant and a regular neutral peer symbol, preserving recording/error/model-status colors where meaningful.
- Embedded Settings sections `ConversationExportView.swift:13–20` and `PortableKnowledgeSharingView.swift:16–24` retain large blue/green filled icon tiles. Their section headings belong to the 14 pt embedded-section variant, not the standalone modal-title variant. These are the same class of nested Settings mismatch caught in v3's live Magic Reply review.

These facts are source-confirmed; exact perceived weight and wrapping remain for root's native pass. No theme or text-size preference was changed here.

### P2 — The ready summary reader footer has an unverified narrow-width layout risk

`DocumentSummaryPanel.swift:33` permits an owned reader as narrow as **440 pt**. At `:170–196`, a ready summary displays Close, Ask Follow-Up, Save to Vault and Copy in one `HStack`; Retry is additionally conditional for other states. With 24 pt outer insets, the minimum reader has only 392 pt of inner width. There is no `ViewThatFits`, wrapping action row or overflow menu in that footer. The multiple padded button labels are a concrete layout risk at that minimum, but clipping was **not** observed in this lane. Render the actual ready reader at 440 pt before asserting failure. Keep Stop/Retry/Close and source coverage visible; do not alter execution or source authority to produce the state.

### P3 — Image inspection's fixed height needs a compact-window check

`ImageInspectionView.swift:193` forces **540×640 pt**, while the main window permits 620 pt minimum height. The scrollable content and separate footer are sound, but the fixed sheet can require parent/window expansion. Inspect the empty, attached-image, answer, and task-handoff disclosure states at the smallest supported native window. This is a verification gap, not a confirmed clipping defect.

## Coverage inventory

All entries in this table were inspected in source only. A native “not checked” is not a failed design state.

| Surface | Classification and current assessment | Safe native state / limitation |
| --- | --- | --- |
| Conversation Trash | Full utility; v3 24/14/13/12 hierarchy and page background already aligned | Open History → Trash; inspect empty/populated, then Done. Do not Restore/Delete. |
| Recently deleted notes | Compact recovery/list modal; 28 pt title and native Done outlier | Knowledge library actions → recently deleted notes; view and close only. |
| Knowledge draft recovery | Compact recovery editor; 28 pt title outlier; meaningful warning/state copy retained | Requires an existing recovery record. Do not manufacture one by editing a real note; source-only if unavailable. |
| New/edit/source-copy note editor | Compact editor; 16 pt title outlier; monospaced Markdown is intentional | Open a blank/editor flow only if it does not create/save data; cancel. Unsaved navigation guard must remain intact. |
| Quote a message | Compact selection modal; 14.5 pt title and 28 pt close target outlier | Existing synthetic message → Quote a passage; inspect and cancel, do not submit a reply. |
| Conversation export section | Embedded Settings form; large blue tile outlier; private clear-text qualifiers intact | Open section only. Export invokes a separate native save panel; cancel that panel. |
| Voice Input | Full utility; v3 page title, regular symbols and form/body hierarchy aligned | Idle state can be viewed; recording/download/transcription require separate state/permissions and were not exercised. |
| Image/window inspection | Full utility; legacy header/tint and fixed-height checks above | Open inspection surface without invoking Inspect or Start Task. Attached/answer states need existing context. |
| Speech Output / speech diagnostics | Embedded Settings sections; v3 14/13/12 hierarchy and neutral symbols aligned | View idle/expanded sections only; no voice download, synthesis or diagnostic action. |
| Writing Profile | Embedded form; v3 hierarchy/panels aligned | View existing form without typing, learning, clearing or saving. |
| Semantic search settings | Embedded disclosure; legacy 12.5/11.5 text, but no large decorative header | Expand/view status only; do not Prepare/Warm/Search. Token consolidation is lower priority than the findings above. |
| Local Knowledge MCP sharing | Embedded disclosure; permission/time-bound explanations and Stop/start distinctions intact | View inactive selection. Do not Start sharing, copy credentials or change note selections. Active state remains source-only unless already active. |
| Portable archive settings section | Embedded section; large green tile outlier | View Create/Open entries without executing export/import. |
| Create archive sheet | Compact modal; 16 pt heading outlier | Empty or existing-note selection can be viewed, then Cancel. No archive creation or recovery-code generation. |
| Open archive sheet | Compact modal; 16 pt heading outlier | Empty form and Cancel. Do not choose/unlock a private archive or enter a recovery code. |
| Consolidation review | Compact review/editor; 16 pt heading outlier; exact source excerpts and local-copy qualifiers intact | Requires an existing entity/review; no Resolve/Generate/Save operation to manufacture state. |
| Native action review / enlarged image | Evidence/review surface; semantic black/white gesture marks are intentional, not arbitrary accent icons | Only inspect if a real review is already pending; never approve/dispatch to obtain a screenshot. Enlarged source title is older 14.5 pt compact heading. |
| Reviewed/private source questions | Embedded question/answer forms; bounded inputs and local/read-only qualifiers retained | Source-only unless a response is already present; no new question/model invocation during read-only audit. |
| Document summary reader | Full owned utility; older 16 pt title/body13.5 plus narrow footer risk | Existing ready reader only; do not capture private app/source or generate a summary solely for audit. |
| Factory reset confirmation | Compact destructive modal; 18 pt title/large warning symbol may be intentional; danger-button contrast/focus defect above | View confirmation only if safely reachable. Do not acknowledge/confirm/reset. Preserve danger semantics. |
| Clean uninstall confirmation | Compact destructive/progress modal; native-confirmed truncated exclusion sentence, older 18 pt title and custom danger control | Root viewed and cancelled confirmation only; no execution. Progress/error states remain source-only. |
| App Update section | Embedded Settings form; legacy 38 pt blue update tile/14.5 pt heading | View idle status only; no update/install action. |
| Native alerts and macOS file panels | Platform surfaces, intentionally separate from custom page title metrics | New folder/rename/link alerts and save/open panels can be cancelled; do not restyle native system typography simply to match a custom 24 pt title. |

## Handoff

No application files were changed. The inventory can be combined with root's native observations; distinguish inspected empty/idle surfaces from conditional recovery, sharing, recording, image-answer and review states that were unavailable. Prioritize the measurable danger-contrast issue, clustered header/section-symbol mismatches, and actual narrow-reader rendering before cosmetic half-point token differences.

## Root-reported native evidence

Root subsequently reported that the actual **Voice Input idle** sheet was rendered through the mic context menu: its 24 pt title, neutral mic, 13 pt forms, 12 pt metadata, 15 pt transcript placeholder and visible Start/Use/Send actions were coherent, with no observed clipping. Recording, error and populated-transcript states were not triggered. This is root's native observation, separate from this lane's source review.

Root also rendered the actual **Factory Reset initial confirmation**: its enabled “Erase & Return to Setup” action visibly uses white text on salmon, corroborating the exact Night contrast calculation. The pill CTA differs from rounded Cancel, and the large filled warning/reset badge is visibly older than the shared section vocabulary; keep its warning meaning if refined. Root cancelled without execution or checkbox changes. Keyboard focus was not exercised.

Root's **Clean Uninstall confirmation** preview independently confirmed the truncated one-line exclusion sentence described in the new P1 finding. No erase/uninstall action was clicked. These are root-reported native observations, not CUA actions by this lane.

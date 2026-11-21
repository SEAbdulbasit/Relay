# Secondary-page refinement — 21 November 2026

The dashboard's layout remains the accepted reference. This pass changes the structure of secondary pages rather than adding another visual theme.

## Composition

- Settings uses open sections separated by whitespace and hairlines. Redundant outer cards and nested form panels are removed. Decorative section symbols use neutral 14 pt regular SF Symbols. Capability, permission, error and readiness information retains its semantic treatment.
- Provider descriptions appear for the selected provider; readiness remains visible for all choices. Model import, Calendar and file actions sit below explanatory headers. Preset and reasoning settings occupy separate rows. Compact permission/update action groups can wrap.
- Knowledge opens fewer collections by default, replaces the row of scope chips with a labeled Collection menu and groups secondary tools under labeled actions. Indexed-file detail is collapsed and rows lose redundant enclosing cards. Existing note navigation and draft guards remain.
- Morning Brief keeps one primary preparation control, a subordinate Instructions control and quieter selectable TODO rows. Shared dashboard/card-deck composition remains unchanged.
- Compact dialogs use a 17 pt title role, consistent header controls and calmer unboxed scope information. Full utility pages retain 24 pt titles. Native system alerts and file panels remain platform surfaces.
- Speech, writing preferences, conversation export and diagnostics follow the same open-section layout. Export scope and privacy explanations remain fully visible.

## Correctness within the visual pass

Destructive buttons use appearance-appropriate ink, a rounded 8 pt shape, explicit focus treatment and opaque semantic fill darkened on interaction. A focused regression checks normal/hover/pressed contrast in Light and Night. Uninstall exclusions wrap in full. Summary footer actions can wrap; image inspection has a flexible height. Stale history and Morning Brief destination descriptions are corrected.

Three parallel implementation lanes handled Settings, Knowledge/Brief and dialogs; the primary lane integrated shared components and utility refinements. No new dependency was introduced. No commit or push is part of this request.

## Verification

The targeted run passed **75 tests across 13 suites** in 0.411 seconds after compilation. It covers palette readability (including the new destructive-fill interaction regression), Knowledge draft/navigation recovery, note Trash, writing profiles, command/note destinations, Brief handoffs, saved responses, thread recovery, voice/speech stores and shortcut routing. Log: `/tmp/relay-refinement-v4-tests-2026-11-21.log`.

The signed debug app built and passed the build script's strict deep signature verification. Final log: `/tmp/relay-refinement-v4-final-build-2026-11-21.log`; app: `build/Relay.app`. Final visual-only changes to the Collection menu label and Brief field container/targets followed the test run and were compiled and inspected in that final build.

Native Night inspection covered General, Sources, Magic Reply, Automation, AI Models and System & Data at the compact Settings sheet size; Knowledge library/reader at the existing wide main-window size; populated Morning Brief; empty Note Trash; sharing with its operational sections collapsed; and the initial Clean Uninstall confirmation. The previously crowded model/file/Calendar headers fit without the observed truncation. The uninstall exclusion statement now wraps completely, including “never modified,” and its destructive action uses readable dark ink. The primary lane cancelled this preview without executing it.

The first rendered Collection menu hid its selected value in the native label. This was corrected to one explicit “All collections”/named-collection label and verified after rebuilding. A remaining nested Brief editor panel was removed and the resulting long plan fields were verified wrapping without editing their contents.

Light appearance, provider-specific configuration variants, recording/error/image-answer states, summary-ready footer and conditional recovery/progress screens were not freshly rendered during this pass. Their code compiled; they are not claimed as visually passed. No preparation, export, sharing, recording, permission grant, model/provider selection, deletion or external action was executed during native qualification. No user content was edited.

Relay is left on Night Home with History hidden and an empty composer. Existing uncommitted work is preserved; no commit or push was performed. `git diff --check` is clean.

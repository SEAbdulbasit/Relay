# Relay identity and cross-page consistency

The user rejected the previous Home as too close to Reference and identified the mismatch with Settings and other pages. This pass keeps the useful calm reading/input structure while giving Relay a distinct composition and applying one shared page language across the app.

## Shared language

Ink/porcelain canvases, one restrained teal accent, a broad offset teal ambient field, and neutral panels replace the copied blue/wine/amber crown and warm standalone utility skins. The page scale is 24 pt title, 14 pt section heading, 13 pt controls/body, 12 pt metadata, and 15 pt reading/input. Peer symbols are regular outlined 14 pt symbols with 32 pt targets. Standard action buttons share an 8 pt continuous radius; panels use 12 pt. Semantic recording, warning, failure and verified-result colors retain their meanings.

The shared palette and legacy surface/glass/lit-card implementations are aligned so nested provider and source panes inherit the same surface language. Compatibility APIs remain intact; decorative rim gradients, glows and repeated shadows are removed. Reduce Transparency and Increased Contrast retain their solid/defined-edge alternatives.

## Composition and ownership

- Home has a left-aligned Relay mark, an invitation and short explanation, the input immediately below, and draft suggestions underneath. It no longer uses Reference's centered question/prompt/dock arrangement.
- Settings uses a quiet navigation rail, consistent page titles and grouped forms, neutral section symbols, and teal selection.
- Knowledge retains its library/reader purpose but shares the same toolbar, controls, surfaces, metadata scale and links. Draft guards, recovery and note identity remain unchanged.
- Morning Brief uses a title/close row and a compact action row, neutral preparation panels and readable state labels.
- Voice, speech, writing-profile, diagnostics and conversation-Trash views adopt the same page/section hierarchy according to whether they are standalone or embedded.

Root owns Home and shared foundations; three parallel lanes own Settings, Knowledge, and Brief/secondary pages. No backend, permission, source-selection, sharing, preparation or destructive action is authorized merely by this visual pass. Live qualification must avoid executing those actions.

## Qualification

The integrated target run passed **77 tests across 12 suites in 7.216 seconds**. It covers palette readability, notch design parity, Knowledge draft/navigation recovery, saved responses, note Trash, thread recovery, task continuation, writing profiles, Brief handoffs, and voice/speech state. Build and strict deep signature verification passed. Logs: `/tmp/relay-redesign-v3-tests-2026-11-21.log` and `/tmp/relay-redesign-v3-build-2026-11-21.log`.

Root reviewed operational-line diffs for Settings, Knowledge, Brief, Voice and conversation Trash: action bindings and guards are retained; Brief's actions were rearranged into the compact toolbar without changing their handlers. The final native cross-page inspection is recorded below when complete. No commit or push is requested for this pass.

### Native finish gate and corrections

An independent agent inspected the running Home at wide and approximately 900 pt widths, Settings General/Magic Reply, Knowledge library/reader, and Morning Brief. The review found three concrete residual defects: a truncated Knowledge navigation label, older large colored badges inside embedded login/Magic Reply sections, and long plan fields clipped to one line.

These were corrected in the final pass. The navigation label is now concise; login, shortcut and Magic Reply section symbols match the neutral shared vocabulary; Magic Reply's unnecessary nested field panels are removed. Morning Brief Goal and Step inputs use bounded vertical expansion with their existing bindings intact, and actual long plan text was visually verified wrapping without editing it.

The final targeted run passed **108 tests in 17 suites in 7.054 seconds**, adding login, shortcut-routing/preferences and focused-draft coverage. Final logs: `/tmp/relay-redesign-v3-final-tests-2026-11-21.log` and `/tmp/relay-redesign-v3-final-build-2026-11-21.log`. The final signed app passed strict deep signature verification and the source diff is whitespace-clean. A final indentation-only cleanup followed qualification; no semantics changed.

Root then directly inspected the final Home, Magic Reply settings, Morning Brief's wrapping fields, and a synthetic saved note in Knowledge. Home and General Settings were also checked in Light, then restored to Night. Native navigation remained reachable and no content was edited, prepared, sent, granted, deleted or executed during this visual inspection. Secondary voice/speech/writing/diagnostics/Trash changes were compiled and regression-covered but were not individually opened in the final native pass. Existing login-registration status was merely displayed; no login-item action was performed.

The app is left open on Relay's distinct Night Home with history closed and an empty composer. Changes remain uncommitted for user review.

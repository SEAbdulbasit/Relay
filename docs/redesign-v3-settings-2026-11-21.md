# Relay settings: unified page language

21 November 2026. Implemented only `Sources/Relay/SettingsView.swift`; no account, permission, provider, source selection, or maintenance action was performed.

The Settings shell now uses the shared Relay page background, a 216 pt neutral sidebar, a quiet 48 pt Settings header, and one 24 pt content title. Navigation groups use ordinary mixed-case labels rather than monospaced uppercase breadcrumbs. Content width is bounded at 760 pt with consistent 28 pt insets.

All setting-section glass/glow wrappers in this file now use the shared neutral page panel. Decorative colored icon tiles became 14 pt outlined symbols. The heading/body/metadata scale is the shared 14/13/12 pt vocabulary. Provider rows and sidebar selection use the restrained Relay teal, while actual health/error/danger states retain their semantic treatment. Appearance previews use the same cool ink/porcelain character.

All existing tab/search routing, control bindings, provider selection, permission/review boundaries, source scopes, factory reset/uninstall flows, confirmation dialogs, asynchronous work and accessibility identifiers are preserved. Embedded provider/source components inherit the shared palette and button treatment; their own implementation remains outside this file's ownership.

Validation in this lane: Swift frontend parser and scoped `git diff --check` passed. No build, test execution, or native UI inspection was performed here; root owns integration and rendered qualification.

## Independent native cross-page review

The signed integrated build was opened and inspected through native accessibility and rendered screenshots. Home was read in its existing wide window and then at approximately 900 pt width using Window → Move & Resize → Top Left. The left-aligned Relay introduction, input, and suggestions below it are visibly distinct from the previous centered reference-derived layout. Neutral ink/teal and ordinary outlined navigation symbols are coherent.

Settings General and Magic Reply were navigated without changing controls. General's title, sidebar and neutral panels align with the shared vocabulary. Concrete defects observed: the 216 pt sidebar truncates “Knowledge & Memory”; embedded Launch-at-Login and Magic Reply content still show large colored section tiles (power, purple wand, blue CPU) that differ from the main Settings section icons. These were reported to root for a bounded shared/component correction.

Knowledge's Library toolbar and existing reader were inspected without opening edit mode. The title, teal selection, outlined controls and neutral surfaces match the other pages; no material header clipping was observed at the compact size. No note content is copied into this report.

Morning Brief's title, controls and neutral cards match. An actual existing Action Plan exposes a usability defect: long Goal and step values are single-line editable fields that cut off their visible text. Wrapping vertical fields with bounded expansion was recommended to root; bindings and action/review boundaries should remain unchanged.

No preparation, task sending, source grant, permission toggle, note edit, deletion, or setting change was performed. Night was left unchanged. The app was returned to Home with history closed and an empty input. CUA completion was recorded and control released to root. This review does not claim that the reported defects were already fixed in the inspected build.

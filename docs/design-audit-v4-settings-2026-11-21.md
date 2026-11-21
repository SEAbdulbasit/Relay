# Settings and embedded-page audit — 21 November 2026

Read-only source audit. No source edits, builds, account actions, permission changes or CUA inspection were performed in this lane. Root owns rendered verification. Values below compare current source with the shared Relay page vocabulary, not an invented new visual identity.

## Prioritized findings

### 1. Destructive button text fails contrast in Night

`Sources/Relay/UninstallAndResetCoordinator.swift:583` uses white enabled text over `RelayColors.accentCoral`; the opaque Night fill is `#F87171` (`RelayDesignSystem.swift:427`). Computed sRGB contrast is **2.77:1**, below 4.5:1 for the approximately 12.5 pt label. Light's `#CD2121` yields 5.48:1 with white. This affects the actual factory-reset and clean-uninstall action style, independently of whether those actions are executed. Existing palette tests check semantic foregrounds on canvases, not white ink on semantic fills.

Use mode-appropriate contrasting ink or a dedicated darker destructive fill. `RelayColors.buttonInk` already represents dark ink in Night and white ink in Light. Verify default, hovered and pressed fills. Keep the red destructive meaning, wording, disabling rules, confirmation boundaries and operation handlers. The style also retains a capsule shape at lines 593–602 while other shared action buttons now use an 8 pt continuous rectangle.

### 2. Unvisited embedded sections still use the old colored tile vocabulary

Core Settings and Magic Reply/login were updated previously, but the following embedded sections still render a 36–38 pt tile with a 16–17 pt colored/filled symbol. The common section vocabulary is a neutral 14 pt regular symbol in a 24 pt layout slot. These are decorative section labels, distinct from adjacent connection/readiness/error indicators.

| Source | Exact anchor | Decorative section |
| --- | --- | --- |
| `LMStudioSettingsView.swift` | 21 | Purple server tile |
| `OpenRouterSettingsView.swift` | 12 | Cyan network tile |
| `CustomResponsesSettingsView.swift` | 24 | Amber filled bolt tile |
| `ClaudeSettingsView.swift` | 65 | Green sparkles tile |
| `WorkspaceCodexOption.swift` | 164 | Blue filled terminal tile |
| `OCRReadinessSettings.swift` | 165 | Green OCR tile |
| `NativeSourceConnectorsView.swift` | 40 | Blue filled inbox tile |
| `DirectMCPConnectorView.swift` | 58, 318 | Blue MCP and purple terminal tiles |
| `MailWorkflowAccessView.swift` | 11 | Blue filled envelope tile |
| `PreparationScheduleView.swift` | 21, 290 | Gold daily schedule and plugged-in analysis tiles |
| `NotchTouchCalibration.swift` | 1961 | Purple filled hand tile in the embedded settings section |
| `AppUpdateView.swift` | 11 | Blue filled update tile |

The same views mostly retain legacy `relayHeadline` 14.5 pt, `relayBody`/`relayBodyStrong` 13.5 pt and `relayCaption` 11.5 pt instead of section/body/caption 14/13/12. Normalize embedded section labels rather than turning every child section into a 24 pt page title. Keep semantic status colors and genuine hardware/calibration illustrations.

### 3. Custom Responses has a fixed-width settings row that cannot comfortably fit the minimum sheet

`CustomResponsesSettingsView.swift:52–99` puts an 80 pt Preset label, 200 pt picker, a spacer, Reasoning label and 120 pt picker in one HStack. Settings currently permits **820 pt** (`SettingsView.swift:186`), with a 216 pt rail and 64 pt content insets. After the card's 40 pt padding and its inner group's 28 pt padding, this row has approximately **472 pt**. The fixed controls and gaps alone require roughly 520 pt, forcing label compression/wrapping or overflow.

Use structural reflow for this row (two labelled rows or a `ViewThatFits` narrow variant). Root should render the Custom Responses provider at the actual minimum sheet width and with an applied long endpoint/model. This is a source-established width conflict; no rendered clipping is claimed by this lane.

### 3a. Root-confirmed compact header crowding on catalogue and Sources

Root subsequently inspected the current approximately 820 pt Settings sheet and reported these concrete rendered defects:

- **AI Models catalogue:** `SettingsView.swift:565–582` places the title, “Apple Silicon LiteRT-LM” badge and Import model action in one horizontal header. The title wraps onto two lines while the badge becomes “Apple Silicon LiteRT-…”. This is catalogue-header crowding; root did not report a provider-list legibility defect.
- **Authorized files/folders:** `SettingsView.swift:1001–1018` puts explanation and both Add actions on one row. Root saw “Add files…” and “Add folder…” each wrap onto two lines in the compact header.
- **Calendar:** `SettingsView.swift:942–975` keeps heading, permission badge and Refresh action on the same horizontal header, leaving the important permission explanation in a narrow column. Root reported the controls technically fitting but visibly squeezing this copy.

These are P2 layout/refinement issues established by root's native review, separate from this lane's source-only inspection. Keep the complete capability/permission/source-scope explanation. Reflow compact actions onto a second row via a narrow layout or `ViewThatFits`; allow full badge text to remain readable. Do not shorten qualifiers or trigger Import/Add/Refresh to verify geometry.

### 4. Provider and automation pages retain unnecessary nested form panels

Examples: `LMStudioSettingsView.swift:102–109`, `PreparationScheduleView.swift:79–87`, plus the provider groups in OpenRouter/Custom Responses/Claude. Shared glass/lit modifiers are now neutral, but these children still add a separate filled, bordered inner form group inside the enclosing card. The prior Magic Reply pass removed this exact extra layer. Flatten one grouping layer where spacing/dividers already communicate the relationship; preserve text-entry field boundaries and meaningful reviewed-output containers.

### 5. Compact action rows deserve explicit rendered coverage

Source candidates: `SettingsView.swift:1221–1226` (three microphone/speech/privacy actions), `LMStudioSettingsView.swift:111–132` (model/image/disconnect/workspace actions), and `AppUpdateView.swift:29–59` (check/release/GitHub). These are horizontal-only rows with dynamic labels and no explicit narrow variant. They are **verification targets**, not confirmed overflow bugs. Do not remove actions to satisfy a screenshot; reflow when required.

## Coverage inventory

Every row is source-reviewed or explicitly scoped as an operational/native state. No row below means “rendered.”

| Settings location | Custom view/source coverage | State and boundary notes |
| --- | --- | --- |
| Shell/navigation/search | `SettingsView.swift` — all nine destinations, sidebar, content header, search results | Shared page titles and normal navigation already aligned; source-only |
| General | Appearance options in `SettingsView.swift`; `LaunchAtLoginView.swift` | Current login section symbol already neutral; registering/unregistering must not be invoked for design QA |
| AI Models — catalogue | `WorkspaceProviderRow`, `OnDeviceCatalogModelCard` in `SettingsView.swift` | Selected/installed/downloading/error variants; downloads, deletion and model preparation not executed |
| AI Models — LM Studio | `LMStudioSettingsView.swift` | Port/model/readiness/vision/error and workspace-use states; no discovery/network checks |
| AI Models — OpenRouter | `OpenRouterSettingsView.swift` | Upload consent, key/save/remove, model/check states; keys and consent untouched |
| AI Models — custom Responses | `CustomResponsesSettingsView.swift` | Preset, endpoint, reasoning, key draft and disclosure states; width conflict above |
| AI Models — Claude | `ClaudeSettingsView.swift` | CLI readiness, rejected token, sign-in, model fields; no login or capability check |
| AI Models — Codex | `WorkspaceCodexOption.swift` / `CodexProviderSettingsView` | CLI/configuration/readiness/diagnostics variants; no checks or config writes |
| Sidekick & Shortcuts | Root setting rows in `SettingsView.swift`; `QuickTextActionShortcutsView.swift` | Shortcut assignments, toggle disabled relationships and Stop access remain meaningful |
| Notch touch | `NotchTouchCalibration.swift` settings section and calibration view | Embedded tile is inconsistent; 28 pt calibration heading and sensor illustration are purpose-specific and are not automatically defects |
| Read aloud | `SpeechOutputView.swift`; related diagnostic status UI | Previously aligned embedded section; voice preparation/rendering not triggered |
| Magic Reply | `MagicReplyCoordinator.swift` / `MagicReplySettingsView`; `WritingProfileView.swift` | Previously aligned symbols and flat groups; unsent wording, context consent and draft settings retained |
| Source file/folder grants | Root authorized-files UI in `SettingsView.swift` | Native open panels are system UI; no new grant or removal performed |
| Calendar | `CalendarSelectionView.swift`, `CalendarSelectionContent.swift` | Read/write destinations, loading, selected, reset/use states; no refresh, selection, grant or event write |
| Native sources | `NativeSourceConnectorsView.swift` | Live source rows, scope selector, session highlight; no source toggles/sync/access changes |
| Source question/import tools | `PrivateSourceQuestionView.swift`, `ChatArchiveView.swift`; referenced `ReviewedSourceQuestionView.swift` | Source-entry/visual-construct scan; detailed smaller-dialog ownership overlaps the parallel dialog lane; no file import or question execution |
| Remote/direct MCP | `DirectMCPConnectorView.swift` | Catalog, OAuth/setup, manual endpoint, discovered schema/output/review states; unconnected/response-only states source-only |
| Mail workflow access | `MailWorkflowAccessView.swift` | Unsent/review boundaries retained; no scope reset, grant or mail operation |
| Knowledge & Memory | `KnowledgeView.swift` settings pane, `SemanticSearchView.swift` entry | Analysis/status/recovery details remain task-specific; search/build not executed |
| Knowledge sharing | `LocalKnowledgeMCPSettingsView.swift`, `PortableKnowledgeSharingView.swift`, `HostedKnowledgeMirrorSettingsView.swift` | Disclosure, endpoint/token, mirror confirmation variants; detailed sharing dialogs also in parallel lane; no enable/disable/copy/share |
| Automation | `PreparationScheduleView.swift`, `PluggedInAnalysisScheduleView`, `MorningBriefNotifications.swift` | Daily/hour/minute, plugged-in limits, read-only progress and semantic status; no schedule/toggle/preparation/notifications changed |
| Wake setup | `PreparationWakeSetup.swift` logic and schedule wake disclosure in `PreparationScheduleView.swift` | Hardware/service-dependent variants source-only; never install/start a service for visual QA |
| Permissions | Root screen/accessibility/microphone/speech sections; `OCRReadinessSettings.swift` | Permission-dependent branches source-only; no request/open-system-settings/retry run |
| System & Data | `AppUpdateView.swift`, `ConversationExportView.swift`, `DiagnosticsView.swift`; root history controls | Existing status/diagnostic monospace is appropriate; no network check, export or history clear |
| Reset/uninstall | `UninstallAndResetCoordinator.swift` / `FactoryResetSheetView`, `CleanUninstallSheetView`, `RelayDangerButtonStyle` | Confirmation, progress, warnings and completion branches source-only; do not execute destructive actions for coverage |
| Reusable drafting helper | `DraftModelSettingsView.swift` | Source-defined helper reviewed; no direct route from current Settings body found, so not counted as a separately reached page |

## Rendered verification matrix for root

1. Night and Light: General, AI Models provider detail, Automation and Sources with collapsed/expanded children.
2. Minimum 820 pt sheet: Custom Responses preset/reasoning, long selected model names, privacy action rows, account/status badges.
3. Source-only operational states: describe unconfigured/error/loading/connected, permission-denied, calibration, wake installation and destructive progress branches honestly if they cannot be reached without changing state.
4. Inspect reset/uninstall confirmation shell only if root can open it without committing an action; inspect/measure destructive contrast independently of executing anything.
5. Keep distinctions between decorative section symbols and semantic status indicators. Do not neutralize warnings, remove source-sharing qualifiers, or make approval controls less explicit.

## Root-reported native coverage, current audit

This is root's observation record relayed to this lane, not independent CUA work by the author.

| Destination | Current audit status | Limits |
| --- | --- | --- |
| General | Prior v3 native coverage only; not newly rendered in this audit as of this update | Do not count the earlier pass as a new v4 render |
| AI Models | Root rendered the current minimum-width page, provider navigation and catalogue header | No active provider selection was changed; LM Studio/OpenRouter/Custom Responses/Claude/Codex conditional detail forms remain source-only |
| Sidekick & Shortcuts | Root rendered the destination | Only reported visible content is qualified; calibration, permission and hardware-dependent branches remain source-only |
| Magic Reply | Root rendered the destination | No draft/provider/toggle/instruction setting was changed |
| Sources | Root rendered the destination and file/folder/Calendar headers | No grants, selections, Calendar refresh or ingestion were performed |
| Knowledge, Automation, Permissions, System & Data | Source-reviewed in this lane; current root native inspection not yet reported here | Do not imply completed native coverage |
| Reset/uninstall confirmations and progress | Source-only in this lane | Destructive operations must not be run for design coverage |

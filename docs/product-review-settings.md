# Relay settings and secondary-view review

Reviewed 20 November 2026 against the current working tree. Existing uncommitted work was preserved. This is a source-level audit and implementation record; runtime screenshots, keyboard/VoiceOver verification, account connections and permission prompts are not claimed here. The coordinating review owns integrated build/test and visual evidence.

## Direction and priorities

Keep the existing native, restrained settings shell: nine named sections, a persistent sidebar, searchable section destinations, semantic colors and native controls. Put operational status beside the affected setting, explain whether edits apply immediately or need approval, and keep Stop available while work is pending. Advanced integration and diagnostic details stay behind existing disclosure groups. No dependencies or backend capabilities were added.

Prioritized plan before editing: (1) cancellation and model/provider control integrity; (2) truthful inference/location copy and explicit saves; (3) permission visibility and field accessibility; (4) compact provider/catalog layouts; (5) verify via integrated build, focused existing tests and the running app. Parent received findings before changes.

## Findings and changes

| Severity / evidence | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| High, confirmed in source | `OpenRouterSettingsView`, `CustomResponsesSettingsView` | Enclosing `.disabled(store.isRunning)` disabled Stop checking because `isRunning` includes model preparation. | Keep the containing group interactive during preparation; individually disable setup/check controls. | A user can cancel a slow or stuck readiness check. |
| Medium, confirmed in source | `SettingsView.modelSettings` | Provider rows stayed enabled while a task was running or awaiting review. | Lock provider selection during current work and explain the dependency. | Prevent accidental context/provider changes mid-task. |
| Medium, confirmed in source | `SettingsView.deleteCatalogModel` | Deletion errors were discarded; active selection was cleared before deletion was known to succeed. | Delete inside `do/catch`, clear selection only on success, and show a recoverable error on failure. | Avoid silent failures and preserve usable state. Actual filesystem failure injection remains untested. |
| Medium, confirmed in source | `WritingProfileView.suggestStyle` | Analysis claimed to occur “on this Mac”, but closure calls the selected workspace provider. | Name the workspace model and explain when examples are sent to it. | Match cloud/local behavior honestly. |
| Medium, confirmed in source | `WritingProfileView` | Add Example allowed input that the profile would reject later (more than five samples / byte limits). Clear Profile erased saved preferences immediately. | Enforce existing sample limits before addition, describe limits, and confirm clearing a saved profile. | Help users recover before save and protect intentional saved preferences. |
| Medium, confirmed in source | `CustomResponsesSettingsView`, `OpenRouterSettingsView` | Some empty-title text/secure fields exposed identifiers without accessible names. | Add explicit API URL, model ID and endpoint key labels. | Identify fields without relying on neighboring visual text. VoiceOver inspection is pending. |
| Medium, coverage gap | `SettingsView.permissionSettings` | Permissions listed screen capture and Accessibility; microphone/speech authorization states required finding the recording workflow. | Add separate current statuses and direct System Settings links, refreshing on app activation. | Explain why dictation is unavailable without starting recording or causing a permission prompt. |
| Low, confirmed in source | `OpenRouterSettingsView` | Key save status appeared only in general model status, far below the input. | Show scoped success feedback adjacent to key controls. | Make the outcome visible where the change happens. Failed saves continue to use store errors. |
| Low, design opportunity | `SettingsView.sidekickInstructionsSettings`, `memorySettings`; `WritingProfileView` | Mixed immediate-save and explicit-approval controls relied on inference from buttons. | State automatic save behavior and limits beside instructions; describe immediate memory edits and explicit style approval. | Remove ambiguity without a blanket save button. |
| Low, layout risk from source | `WorkspaceProviderRow`, `OnDeviceCatalogModelCard` | Provider status competed horizontally with description; catalog heading had title plus three badges. | Put status beneath description, allow two lines, and use a compact model specification line. Remove unverified “128K Context” / “Vision + Tools” badges. | Preserve readable status in the settings content column and reserve readiness claims for actual checks. Runtime size checks remain pending. |
| Low, navigation opportunity | `SettingsView.navigation` | Search required a pointer action. | Add Command-F to focus search and an explicit accessible search name. | Support familiar macOS settings navigation. |

## Destination and state coverage

“Inspected” below means source reviewed, not exercised live. The root report should add runtime outcomes independently.

| Destination | Children / important states inspected | Result / limitation |
| --- | --- | --- |
| General | Appearance (light/dark/system), launch at login | Existing immediate preferences preserved. Theme rendering and launch-service registration require runtime checks. |
| AI Models | Six provider rows; local catalog/import/load/unload/compute; download/pause/verify/delete; advanced computer-use engine | Provider locks, compact catalog, truthful capability messaging, surfaced delete errors implemented. Multi-GB download and engine update were not initiated. |
| OpenRouter | Upload consent, secure key save/remove, model ID, discovery, model/image checks, cancel, general/error/vision status | Labels, feedback and preparation/cancellation controls improved. No paid requests or real credential writes performed. |
| Responses API | Presets, reasoning, applied URL, local-key requirement, URL-scoped key save/remove, model discovery/check/images/cancel | Existing key admission/epoch protections preserved; labels and preparation/cancellation controls improved. Local/remote server execution delegated to root tests. |
| LM Studio | Local host/port, discovery, selected/missing model, check/images/disconnect/cancel, status/error | Preparation controls reflect busy state; cancellation remains outside disabled inputs. Requires a running local server for live success. |
| Claude / Codex | CLI sign-in/configuration/readiness and workspace selection | Existing destination code located/reviewed. Authenticated CLI flows not performed in this lane; no new readiness claims. |
| Sidekick & Shortcuts | Shared key; every-display handle; compact state; single tap; hold-to-dictate; release-to-send; quick access; selected text; global stop; proofread/summarize shortcuts | Dependency toggles preserved. Save contract/byte usage added for instructions. Global key registration and multi-display behavior need live checks. |
| Sidekick advanced | Touch calibration, custom instructions, read-aloud | Existing disclosures preserved. Touch hardware, audio output and interrupted playback not exercised. |
| Magic Reply | Separate provider/preferences, custom reply instructions, collected writing examples, manual writing profile, optional AI style suggestions | Honest provider-location language, sample guardrails and explicit saved-profile clearing implemented. Actual focused-app draft injection is outside this lane. |
| Sources | Explicit file/folder grants, writable toggles/removal, Calendar request/refresh/error/selection, local connectors | Existing scoped admission preserved. Calendar permission, Apple Mail/Notes/Messages/WhatsApp and full-disk access were not granted or modified. |
| Service connectors | OAuth presets/client fields/cancel/connected accounts; direct MCP endpoint/token/tools/resources/read preview; Mail sending access | Source destination map inspected. Network authorization, sends and service mutations not executed. |
| Knowledge & Memory | Empty/current memory; add/approve/edit/delete; semantic vault build/progress/stop/resume/reveal | Explicit memory save behavior and simpler vault description implemented. Indexing real personal data was not initiated. |
| Local index | Index/refresh/cancel/export/clear; semantic search; record list/forget | Source reviewed. Root follow-up implemented show-all/fewer indexed files and a confirmation explaining Clear Index. Runtime populated-index inspection remains pending. |
| Knowledge sharing | Local MCP note selection/start/stop; encrypted archive create/open; hosted mirror setup/access activity | Destination code reviewed. Encryption/archive round trip and live sharing/hosted credentials not exercised. |
| Knowledge workspace secondary | Vault sidebar, note reader/editor, wikilinks, new folder/note, generated review, sharing/writing-style modals | Identified in navigation/source map; full interactive editor/review verification belongs to coordinating workspace lane. |
| Automation | Proactive cards toggle/manual analysis/stop/error; plugged-in scheduler and recent runs; daily hour/minute, selected sources/calendars, notifications, wake helper/command | Source reviewed; existing progressive disclosure retained. Actual OS wake schedule and notifications were not changed. |
| Permissions | Screen Recording status/settings/check; Microphone & Speech states/settings/check; Accessibility request/settings/check; native control toggle/routine-action approval; OCR readiness | Voice statuses added; routine-action control disabled when window control is off. No prompt or permission change occurs just by opening settings. Live system-pane navigation requires verification. |
| Permission diagnostics | Accessibility self-test, computer-use probe, capture check; status/error | Existing controls preserved. Fixture checks and system dialogs not run by this lane. |
| System & Data | Update idle/checking/result/failure; conversation export format/activity/save/cancel/error; clear-history confirmation; technical diagnostics export | Source reviewed. No network update or export containing personal data was initiated. |
| Reset / uninstall | Confirmation, keep/delete models, running/partial warnings/recovery/complete | Source reviewed. Destructive actions intentionally not executed as verification. Existing guards/confirmation retained. |
| Settings shell | Section aliases, grouped navigation, search no results/results/clear, close/Escape, per-section scroll identity | Added Command-F. Tab order, focus visibility, narrow/large-text layout, all themes and VoiceOver remain runtime checks. |

## Verification

- Passed Swift parser validation for all five modified views with `/usr/bin/xcrun swiftc -frontend -parse` (SettingsView, OpenRouterSettingsView, LMStudioSettingsView, CustomResponsesSettingsView, WritingProfileView).
- No full build was launched concurrently; root owns integrated build/test. Recommended focused existing suites: `OpenRouterProviderTests`, `CustomResponsesProviderTests`, `WritingProfileTests`, `WritingStyleLearningTests`, plus settings/onboarding/permissions suites selected by root.
- Existing profile tests cover Unicode byte bounds, maximum sample count, preservation of previous approval, save/clear behavior and keeping raw samples out of model context. Existing Responses tests cover scoped credential admission. These checks should be run, not replaced with source-string tests.
- No screenshots or performance measurements captured in this lane. Source inspection does not establish contrast ratios, frame timing, actual accessibility names, keyboard focus order or OS permission success.

# Relay product review — 20 November 2026

## Assessment and direction

Relay is a native macOS assistant for conversation, explicit local source access, writing, and reviewable computer tasks. Its working architecture supports on-device and optional external inference, task history/activity, knowledge notes, preparation, and a notch Sidekick. The principal product problem was inconsistent truthfulness of state: illustrative setup data looked measured, failed plans looked complete, and provider controls did not consistently match execution state.

Keep the existing native SwiftUI architecture, system typography, neutral light/dark surfaces, restrained blue selection/focus, and persistent composer. Put the request and result first; expose technical evidence on demand. Use typography and spacing before adding containers. Keep motion short and honor macOS Reduce Motion. Preserve all pre-existing work in this heavily modified checkout.

## References and evidence

- The requested “Sentinet OS” is interpreted as **Sentient OS**, verified against the installed app (`jesai.Sentient-OS-macOS`) and [official product](https://sentient-os.ai/). Its actual home screen was inspected: setup disclosure sits beside the primary composer, and starter prompts explain concrete jobs. Apply contextual discovery and honest example labeling; do not copy its decorative background.
- The installed **Google Antigravity** (`com.google.antigravity`) was inspected at its home workspace, together with its [official product page](https://antigravity.google/). Observed: project grouping, restrained sidebar, composer-adjacent model/execution controls, clear navigation. Apply compact persistent navigation and controls near their effect. Fresh onboarding was not replayed, to preserve the installed account/workspace state.
- [ChatGPT official overview](https://chatgpt.com/overview/) was reviewed for the conversation-first product framing. Authenticated ChatGPT settings/onboarding were not independently exercised; no claim of exact settings parity is made. Restrained conversation width is this review's recommendation, not a measured reference specification.
- [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility) and [Reduce Motion guidance](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria) inform semantic controls, text contrast, and honoring the OS preference.

## Prioritized audit and implementation

Confirmed defects are distinguished from design opportunities. Lane reports contain detailed evidence and coverage.

| Severity / kind | Location | Before | After / correction | Why |
| --- | --- | --- | --- | --- |
| P1 defect | OnboardingView and previews | Invented RAM, speed, note/link counts presented as live | Removed telemetry; labeled fictional demos and selected sources | Setup must not promise unverified work |
| P1 defect | MainView plan/activity | Non-running failed/stopped plan displayed completed | Neutral proposed steps; explicit task phase and failure recovery | Prevent false completion |
| P1 defect | MainView recovery | Inspect & resume immediately resumed | Separate inspect and resume actions | User can review uncertain effects first |
| P1 defect | Provider settings | Cancellation disabled by enclosing busy group; setup controls inconsistent | Cancellation remains reachable; edits/checks reflect actual busy state | Make interruption and recovery usable |
| P1 defect | Settings model management | Deletion errors ignored; selection cleared before success | Surface errors and preserve selection on failure | Avoid silent configuration loss |
| P2 defect | OnboardingCoordinator | Interrupted setup forgot selected Gemma model | Persist validated catalog choice | Resume actual setup intent |
| P2 defect | Settings permissions | Microphone/speech status did not expose current authorization accurately | Read authorization without requesting it; contextual Settings links | Show actual access |
| P2 defect | MainView | Compact layout hid sidebar despite toggle claiming shown | Compact history/activity popover | Preserve navigation at small widths |
| P2 defect | RelayDesignSystem | Dim/faint light text and semantic labels lacked contrast | Opaque readable text and adjusted light semantic colors | Readable metadata and state labels |
| P2 defect | Shared button styles | Custom controls lacked explicit consistent focus ring | Shared blue focus outline using focus environment | Keyboard location is visible |
| P2 defect | MorningBriefView | Card navigation unlabeled and movement ignored Reduce Motion | Named previous/next controls; conditional transitions | Accessible navigation |
| P2 defect | KnowledgeView | Index truncated at eight records without expansion | Show all/fewer indexed files | Make indexed content discoverable |
| P2 opportunity | KnowledgeView | Clear index acted immediately | Review confirmation explaining exact affected data | Avoid accidental loss of derived context |
| P2 opportunity | Shared surfaces | Repeated flat cards all cast shadows | Reserve shared surface shadow for raised cards | Reduce competing depth cues |
| P2 defect | WritingProfileView | Cloud model analysis described as on-device; unclear limits/save | Accurate selected-model wording and explicit save/limits | Understand data flow and persistence |
| P2 defect | Transcript actions | Actions depended on pointer hover | Persistent accessible actions | Keyboard and pointer access agree |

Implementation order: truthful workflows, navigation/recovery, shared tokens/controls, onboarding/settings, secondary-state polish, then integrated checks and actual app review.

## Coverage

See [workspace coverage](product-review-workspace.md), [onboarding coverage](product-review-onboarding.md), and [settings and secondary-screen coverage](product-review-settings.md). These distinguish source inspection from runtime checks; a source-reviewed screen is not a runtime pass.

Root runtime baseline: Sidekick collapsed/expanded with recent conversation, main conversation with existing failure/error/activity/plan, General settings navigation/search, empty Knowledge Vault, and empty Morning Brief. Reference runtime: Sentient home and Antigravity home. No source permissions, credentials, downloads, external messages, or destructive user actions were exercised.

Root code coverage: shared palette/type/spacing/surfaces/buttons, Morning Brief card navigation, Knowledge index overview. Functional regression checks cover phase presentation, setup persistence, existing activity behavior, palette contrast, provider configuration/cancellation and writing settings where runnable.

## Verification and limits

Verification results are recorded below after the integrated run. The implementation does not add per-plan-step completion evidence; plan rows stay neutral until that capability exists. No profiling evidence supports an inference-speed improvement claim. Hardware/OS permission paths, real provider account failures, fresh model downloads, multi-display Sidekick, and external-app autonomous outcomes require dedicated environments and are not implied by UI or source checks. Existing user conversation/model state is preserved.

Integrated automated verification:

- `swift test --jobs 6 --filter 'OnboardingTests|ActivityPresentationTests|WorkspaceTaskPresentationTests|ProductPaletteAccessibilityTests|AuditRoadmapVerificationTests|NotchDesignParityTests|OpenRouterProviderTests|CustomResponsesProviderTests|WritingProfileTests|WritingStyleLearningTests'`: **82 tests in 11 suites passed**. Log: `/tmp/relay-product-review-tests-final.log`.
- New palette regression checks enforce at least 4.5:1 text contrast for eight text/semantic roles against five main surfaces in both light and dark appearances.
- The initial run exposed insufficient light red contrast and an unnecessary reading-width token change. Red contrast was corrected; the established shared width was retained because MainView already caps conversation text at 760 points. The final run passed.
- Targeted `git diff --check` passed for the edited Swift sources/tests. Existing unrelated toolchain warnings remain; no broad rewrite was made to silence them.
- The workspace window minimum is now 760 points once setup is complete, allowing the implemented compact navigation breakpoint to be reached. Setup retains its 860-point minimum.

Live checks of the packaged development build:

- Launched `build/Relay.app`; build and strict code-signature verification succeeded. Existing thread survived restart.
- Resized from the large desktop window to approximately 797 × 648 points, then checked the 860-point regular/sidebar layout. Transcript, composer, model picker and compact history popover remained usable. Screenshots were inspected inline.
- Created one synthetic test conversation, requested `Calculate 23 * 17 using the calculator tool.`, and observed `391`, a separate checked calculation Activity row, and expandable evidence describing the local arithmetic parser. This conversation remains in History as verification evidence.
- Visited every top-level settings destination: General, AI Models, Sidekick & Shortcuts, Magic Reply, Sources, Knowledge & Memory, Automation, Permissions, System & Data. Checked actual microphone/speech/Accessibility/capture statuses without requesting additional permissions.
- Exercised Command-F, settings search no-results and clear recovery. Switched Light → Night → Light and inspected dark settings. Light appearance remained selected after restarting/re-entering setup.
- Re-entered setup, visited all five steps, ran the explicitly fictional Instant Draft practice, reached the preserved Codex provider choice, reviewed optional permissions/source selections, and returned to the same workspace. No model download, account change or new source selection was performed.
- Live inspection found one disclosure with insufficient contrast on a fixed dark welcome demo in Light appearance. The disclosure and one related simulator badge were corrected to fixed light ink and rebuilt.

Remaining runtime gaps: genuinely fresh account/defaults setup (resumption has automated coverage), all provider accounts and connection failures, real model download interruption, external-app task interruption/resume, populated index show-all/clear confirmation, full VoiceOver traversal, text scaling, Reduce Motion enabled at OS level, multi-display/hardware gestures, destructive reset/uninstall and scheduled wake. These are not claimed as passed. The local login item remains unavailable in this development bundle and is visibly reported with recovery guidance. No frame-time or inference benchmark was taken.

Final rebuild completed successfully (`/tmp/relay-product-review-package-final.log`). Relaunched the final signed bundle, confirmed the fictional-example disclosure is readable in the light-theme welcome stage, exercised Finish later, and left Relay in its workspace with the synthetic calculation result and previous history preserved.

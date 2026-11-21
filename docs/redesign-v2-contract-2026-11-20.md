# Relay: a quiet working canvas

This is a structural redesign from checkpoint `2981ea4`, informed by the installed Sentient app, eight rendered Desktop references, its official source, and an independent Relay workflow audit. It replaces the previous editorial welcome screen and dashboard-like history shell.

## Composition

- Chat is the default surface. An unobstructed canvas, unruled transparent 40–44 pt navigation, and a shared 720 pt transcript/input column establish one visual hierarchy.
- History is closed by default in this design generation, opened explicitly through its named control or keyboard command. When open, its 240 pt panel contains a search, plain chat rows, and recoverable Trash. No History/Activity segmented control, count footer, or nested current-chat card.
- Activity is a task-specific inspector, independently dismissible. Opening it must not replace history or permanently expand navigation.
- The empty canvas has a short centered invitation and up to three draft suggestions near the input. No marketing headline, numbered feature rows, duplicated navigation, or configured-provider status block.
- The composer rests as one 56–64 pt row: attachment menu, growing text, dictation, send. Model choice is a subdued control in navigation. Attachments, reply context, recovery and reviews expand only when meaningful.

## Detail

System type: 15 pt conversation/input, 12–13 pt navigation, 22–26 pt empty invitation. Consistent 14 pt regular outline symbols on 30–32 pt targets; larger Send/Stop target. All contextual controls retain accessible labels, keyboard/menu access and focus feedback. Prose and input share column edges.

Broad, irregular blue/wine/warm edge illumination fades into the reading canvas. No rectangular colored header, continuous animation, oversized logo or repeated decorative cards. Materials belong on working surfaces, with solid Reduce Transparency/Increased Contrast alternatives. Reading contrast remains clear in Light and Night.

## Behavior and finish

Preserve backend/tool routing, exact reviews, Stop and steering, recovery, draft protection, stable thread identities, Trash and saved response Open/Export. No new external or Calendar writes are needed for visual verification.

Inspect native empty/chat, history open/closed, model choice, running/Stop, activity, saved-result controls and setup navigation at approximately 900×650 and a wider window, in both appearances. Fix named visual defects after rendering; compilation alone is not a design pass. Keep the signed app open for review. Do not commit or push this redesign without a new user request.

## Implementation and qualification — 21 November

The working workspace now follows this contract. History uses a new, initially closed presentation preference; existing chats and their stable identities remain available. The History/Activity tab bar, count footer, nested current-chat card and two-row input shelf were removed. Message jumps remain in the conversation menu. Activity is an independently dismissible inspector with its own visible Stop action. A newly arriving exact action review dismisses the inspector, and task-activity entry points refuse to cover a pending review.

The reading/input scale is 15 pt; greeting 25 pt; history/filter 13 pt; navigation 12–13.5 pt. Regular outlined SF Symbols use 32 pt peer targets and 36 pt dictation/Send targets. Native attachment and ellipsis menus receive an explicit neutral tint. Status colors retain semantic meaning. Native window controls have reserved space beside the integrated transparent header; its empty background uses Apple's [WindowDragGesture](https://developer.apple.com/documentation/swiftui/windowdraggesture).

The first rendered pass was independently reviewed. It exposed a low attachment-menu baseline, excessive welcome-to-input spacing, a redundant full-width prepared-work disclosure and inconsistent mint menu icons. These were corrected and re-rendered. Prepared work remains in Morning Brief, whose existing content already includes the proactive deck; no duplicate sheet or home card was retained. Task recovery is one compact row with Activity and the currently valid Resume/Continue/New request action.

Final automated checks: **56 tests across seven suites passed in 21.460 seconds**, including palette accessibility, notch design parity, replies, task continuation, Knowledge navigation guards, saved responses and thread recovery. Final signed debug build succeeded; strict deep signature verification and `git diff --check` passed. Logs: `/tmp/relay-redesign-v2-final-tests-2026-11-21.log` and `/tmp/relay-redesign-v2-final-build-2026-11-21.log`. This was a targeted UI qualification, not another full backend/account integration run.

Native inspection covered Light/Night empty and conversation views, approximately 900 pt and wider windows, history open/closed, draft-only suggestion behavior, model-choice popover, saved-response Open/Export affordances and actual Open into Knowledge, return to chat, and the Calendar setup route. Setup inspection made no source-selection or permission changes. No real Calendar writes were performed. Reduced Transparency/Increased Contrast fallbacks are implemented; the OS accessibility preferences were not changed for live testing.

A separate synthetic design-verification chat exercised the actual configured Codex CLI: one harmless explanatory response completed, and a second bounded Stop check was stopped from inside Activity. The inspector showed “Task stopped”; Resume was available in the running session. After relaunch the compact recovery row correctly showed New request when that continuation was no longer valid. The pre-existing conversations were preserved, and no user notes were edited. The final app is open on the empty Night canvas with history closed and no unsent test draft. A wide-window zoom was inspected; fullscreen and actual drag displacement were not independently qualified.

This pass replaces the workspace composition and shared conversation scale. It preserves the existing purpose-specific Knowledge and Settings workflows rather than claiming a complete redesign of every preference or reader component. No redesign changes were committed or pushed.

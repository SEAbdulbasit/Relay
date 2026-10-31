# Relay design reset critique

Read-only source review of `MainView.swift`, `SettingsView.swift`, and `OnboardingView.swift`, plus the saved `relay-final-ui.png` checkpoint. The saved screenshot is historical; fresh app captures are required to approve the new implementation. No source edits were made for this critique.

The present UI spends too much space explaining itself. Large empty margins, nearly equal white values, repeated status copy, and nested bordered rectangles make it look like a development inspector. The redesign should make a clear promise through structure: a calm conversation workspace, an obvious composer, and precise evidence available when requested.

## Changes required

| Before | After | Why |
| --- | --- | --- |
| A tall identity header includes Relay, a slogan, Activity, library and settings with different control shapes. | Compact toolbar: Relay identity on the left; one restrained local-model status; consistent 34–36 pt square utility buttons on the right. | The conversation should begin higher in the window; utility controls need one visual grammar. |
| Header slogan, bottom privacy slogan, model status and completion banner all frame the same task. | One persistent local-state label; contextual task status only while running/stopped/reviewing. Put privacy detail in setup/settings. | Reduces repeated reading without hiding consequential state or uncertainty. |
| Almost every label uses white or 88% white, leaving little hierarchy despite high contrast. | Keep primary copy white. Establish hierarchy through size, weight, whitespace and distinct filled surfaces; reserve secondary white around 75–80% on the dark neutral canvas and measure contrast. | White text can remain legible without every piece of metadata competing with the response. |
| Blue-black canvas and blue-gray cards sit close together, outlined by repeated thin borders. | Neutral charcoal canvas, slightly lighter composer, still lighter interactive hover/selection surfaces; use borders only where focus or grouping needs them. | Surface separation should be visible at ordinary screen brightness. |
| Main chat is 16 pt with generous outer whitespace; metadata and controls are 13–14 pt. | Chat and composer 17 pt, 5 pt line spacing; controls/body settings 15 pt; metadata at least 13 pt and never the only carrier of important state. | Addresses the user's small-text complaint with a coherent scale rather than enlarging everything indiscriminately. |
| Empty chat uses an abstract slogan, stacked suggestion rows and a separate model setup link. | A direct heading such as “What can I help you do?” with three concise real task starters; when unready, show one clear setup card as the primary action. | The first screen should teach the interaction immediately. |
| Composer readiness, return hint, context, microphone, send and privacy copy form several visual bands. | One strong composer surface: draft above, attachment/microphone controls below, compact status and one clear send button. Maintain clear setup-disabled behavior and draft preservation. | Makes the entry point recognizable and preserves the behavior users already understand from chat apps. |
| Activity expands into a large box immediately above the composer and can displace the conversation. | On wide windows, a dedicated right inspector; on narrow windows, a bounded sheet/popover or collapsible panel with its own scroll. | Evidence should be accessible without consuming the workspace used to steer the task. |
| Assistant timestamps sit far to the right; evidence occupies another wide bordered container. | Compact identity/time line and a small disclosure row beneath the relevant response; expand detail on request. | Keeps outcome, ownership and evidence together. Never remove unverified/uncertain outcome information. |
| Settings is fixed at 650×650 with a horizontal pill tab row, a full-width file path and repeated explanatory paragraphs. | A settings rail with icon/text navigation and a content pane: section heading, grouped control rows, one status, advanced details disclosure. Use a larger initial window if needed rather than shrinking copy. | Produces a familiar Mac settings experience and gives long model paths/recovery text a deliberate place. |
| Model settings shows an internal filename, absolute path, compute caveat, probe caveat and offline paragraph at once. | Human model title, compact file location row with middle truncation/selectable full path, compute row, Load/Unload status group; move engine/probe caveats into “Model details.” | Keeps the action obvious while retaining accurate scope and recovery information. |
| Onboarding welcome combines artwork, two-line headline, intro, benefit columns, hardware metrics, hardware summary and a network caveat before footer controls. | One visual focal point, one sentence promise, short readiness strip, one primary Get started action. Keep hardware details expandable; retain a concise setup-download disclosure. | First run should feel light and finite. |
| Onboarding model step exposes every download implementation detail before the user needs it. | One recommended-model card with size, primary action and clear progress. Show pause/error recovery when relevant and provenance/verification under details. | Preserves integrity information while reducing the information needed to take the next step. |
| Accessibility step offers multiple button actions and instructional paragraphs in the same region. | Permission row with current state and one primary action, followed by a separate harmless control-check row; reveal setup/rebuild recovery only when permission is missing. | Permission and actual control qualification remain separate, with a clear next action. |
| Buttons mix plain, bordered, prominent, capsule and circular treatments. | One reusable primary button, one secondary button, one icon-button style, and one destructive treatment across setup, settings and chat. | Consistency makes interaction predictable and improves polish without decorative complexity. |
| Potential redesign temptation: decorate every view with glows, gradients or animation. | Use a single restrained brand accent and the Relay mark. Keep repeated keyboard actions immediate, support reduced motion, and use motion only to explain occasional state transitions. | Emil's frequency/purpose rule prioritizes perceived speed and restraint. |

## Concrete design contract

- Native SwiftUI application; no web-styled navigation, fake conversation history, invented model capabilities, or nonfunctional controls.
- Chat is the primary surface. Settings and evidence have secondary spatial roles.
- Primary text remains white; the dark theme must stay readable at low brightness and in Increase Contrast.
- Use a stable spacing scale: 8, 12, 16, 24, 32 pt. Use at most three obvious corner radii: small controls, grouped cards, composer.
- Important buttons have at least a 32–36 pt target; primary setup buttons at least 44 pt. Native focus rings and VoiceOver labels remain intact.
- Always distinguish “permission granted,” “model loaded,” “action independently verified,” and “task complete.” Visual polish cannot collapse those meanings.
- Local model not ready, preparing, ready, stopped, permission denied, review pending, tool failure, long response, empty transcript and download error each get one purposeful state presentation.

## Finish gate

Approve only after fresh native screenshots of empty chat, a long conversation, pending review, Settings Model/Access/Voice, and all four setup steps. Check both the initial window size and minimum supported size. Inspect keyboard tab order, Return behavior, Escape dismissal, focus visibility, selectable long paths, wrapping with long file names, and reduced motion. Test expanded evidence and Activity so neither obscures the send/Stop controls. No passing functionality test substitutes for these visual checks.

## Revised source checkpoint

The redesign now has a shared neutral charcoal/mint design system, 17 pt conversation text, a collapsible 218 pt navigation rail, a compact 70 pt toolbar, aligned 780 pt maximum conversation/composer columns, direct starter cards and grouped voice panels. Source inspection confirms the message and composer columns use the same inset and width constraint. Collapsing navigation retains a Settings action. Existing scroll-follow safeguards remain in place.

| Before | After / remaining acceptance condition | Why |
| --- | --- | --- |
| Main content and composer had separate sizing formulas. | Both now use the shared 780 pt column and 28 pt inset; visually verify after build. | Establishes a stable conversation axis. |
| “New conversation” visually implies preserving an old conversation, while its action calls `clearConversation()`. | Use an explicit clear-current-chat label/help or explain the absence of history before invoking it. Do not change storage semantics as part of a visual pass. | Prevents users from expecting an archive that does not exist. |
| Activity uses a right-sidebar symbol but still expands below the conversation. | Match its icon to its actual presentation, or implement a true side inspector. | Iconography should predict spatial behavior. |
| Three equal starter cards and a full composer utility row fit the default window. | Inspect 800×620: with the rail expanded the conversation pane is approximately 581 pt and composer interior about 485 pt. Verify wrapping/truncation and a reachable Send action. | Minimum size is the likely regression boundary. |
| Local-model status is now visible in both rail and composer. | Keep one authoritative readiness meaning; consider displaying the composer chip only when the rail is collapsed. | Avoids recreating the old duplicate framing. |

This source checkpoint is provisional, not visual approval. Native screenshots after the integrated build remain required.

## Fresh native screenshot review

Reviewed `design-reset-conversation.png` and `design-reset-settings.png`. The chat text and composer now share an obvious alignment axis, the charcoal surfaces are distinguishable, the settings rail has clear selected state, and Model controls have a readable hierarchy. These are actual native app captures, not mockups.

| Before | After / adjustment | Why |
| --- | --- | --- |
| The rail's “Clear conversation” wraps into two lines. | Shorten to “Clear chat” with explicit help about clearing the current conversation; replace the compose/pencil symbol with a clear/reset symbol. | A primary rail action should remain one line and predict the correct effect. |
| “Gemma · on-device inference” wraps after “on-”. | Shorten to one readable line or remove the duplicate secondary status when the composer already displays Gemma. | Avoids an awkward line break in a permanent status region. |
| Primary action is approximately twice the native secondary button's height. | Use shared 36 pt primary/secondary styles for this settings context, preserving hierarchy through fill and emphasis. | Eliminates an accidental mix of design systems. |
| Native selected GPU segment has dark text on a light-gray fill. | Optional future refinement: accessible custom segmented appearance with a selected white label and restrained mint fill; preserve native keyboard/VoiceOver semantics. | Matches the all-white-label request without weakening usability. |

No additional default-size clipping was visible in these two captures. They do not qualify minimum-size behavior, the collapsed rail, expanded Activity/review states or onboarding screens.

## Final native visual checkpoint

Reviewed the refreshed `design-reset-conversation.png`, `design-reset-settings.png`, `design-reset-focus.png`, `design-reset-onboarding.png`, `design-reset-setup-model.png`, `design-reset-setup-access.png`, and `design-reset-setup-task.png` captures. Observed scope is a 1080×790 main/setup window and an 840×720 Settings sheet. The attempted resize did not establish an 800×620 minimum-window observation; that boundary remains unqualified.

| Before | After | Why |
| --- | --- | --- |
| Clear action wrapped and carried a compose icon. | “Clear chat” fits on one line with a reset symbol. | The visible label and symbol now match the operation. |
| Permanent rail status wrapped awkwardly. | One-line “Local model ready” status. | Removes visual noise without losing readiness. |
| Primary and secondary settings actions had mismatched heights. | Shared 36 pt controls and consistent surface treatment. | Controls now belong to the same system. |
| Focus mode had not been inspected. | Collapsed navigation capture retains Settings and Activity; conversation and composer remain centered on the same readable axis. | The rail can be hidden without removing core utility access. |
| Setup had only source inspection. | All four setup steps now have native captures with legible hierarchy, selected-step state and reachable fixed footer actions. | Confirms the implementation rather than a mockup. |

No material clipping requiring a source change was visible within this observed scope. Model and Access screens contain additional content beyond the scroll viewport; those captures must not be described as proving the entire scroll content or minimum size. Selected CPU/GPU remains native macOS segmented styling, including dark selected text. A nonblocking semantic refinement remains: a green check on a previously visited Mac access step can mean “visited” even when access was skipped; the explicit First task status correctly states that computer control is unavailable. Future refinement should distinguish skipped/visited/granted without changing permission semantics.

This visual checkpoint approves the reviewed default-size hierarchy and composition only. It does not certify all Settings tabs, expanded evidence/Activity/review states, minimum-window layout, VoiceOver, Increase Contrast, or every download/error/permission transition.

## Direction superseded by user feedback

The user rejected the preceding reset and requested a ChatGPT-like conversation interface. The prior default-size visual checkpoint establishes only that those screens rendered coherently; it is not acceptance of that direction. The next main-screen pass should prioritize familiar chat composition over a workspace/dashboard identity.

| Before | Next direction | Why |
| --- | --- | --- |
| Branded rail, WORKSPACE label, permission navigation and permanent model status card. | Quiet navigation with a collapse affordance, honest clear-current-chat action, optional actual Sources action and Settings at the bottom. No fabricated chat history. | Familiar chat should be recognizable without reading navigation categories. |
| Empty greeting and task cards above a bottom-anchored composer. | One centered empty-state question directly above the composer; after the first message the composer anchors at the bottom. | The text input is the primary invitation and should sit beside the prompt to act. |
| Charcoal/mint workspace styling. | Neutral main canvas near #212121, darker rail near #171717 and composer near #303030. White text; color only for meaningful exceptional state. | Aligns the requested visual language without copying a brand or inventing capabilities. |
| Composer repeats model readiness and keyboard instructions. | Clean composer with text area, attachment control and microphone/send controls; one readiness explanation in the top bar. | Avoids making the writing surface resemble a toolbar dashboard. |
| Large framed controls and section dividers. | Quiet toolbar and row actions with hover/focus feedback, generous rounded composer, assistant prose without a bubble. | Strong familiarity comes from hierarchy and placement rather than more decoration. |

Keep existing draft, scroll, permission, evidence and Stop semantics. Do not use cosmetic simplification to obscure unverified outcomes or remove the ability to stop a running action. Verify empty-to-first-message transition without focus loss or duplicate TextField branches, plus reflow on shorter windows.

## Current ChatGPT-style implementation checkpoint

This main-screen iteration supersedes the workspace-style main screen reviewed above. Read-only source review covered `MainView.swift`, and native visual review covered `chat-interface-conversation.png` at 1080×790 with an existing conversation. The default filled screen has no blocking visual issue: neutral-gray canvas, a quiet rail, compact Relay/model header, unboxed assistant prose, right-aligned user bubbles, and a rounded composer with restrained attachment/microphone/send controls. Conversation text and composer share the same alignment axis. The partially visible preceding response at the scroll viewport's upper edge is ordinary scrolling, not evidence of misplaced UI.

| Before | Current implementation | Why |
| --- | --- | --- |
| Workspace heading, large reset action and model status card. | Quiet sidebar with compact reset icon and concise navigation. | The conversation is the dominant object again. |
| Mint-accented status-heavy composer. | Neutral rounded input with simple attachment and microphone/send controls. | Matches the user's requested chat familiarity. |
| Repeated readiness labels and keyboard instructions. | One compact model/readiness label in the toolbar. | Less reading is required before typing. |
| Task starter cards and a large branded empty-state composition. | One question above the composer in the empty-state source layout. | The input becomes the next obvious action. |
| Empty/filled transition risk from duplicating the composer. | The same `conversationDock` stays outside the conditional content branch. | Source structure supports retaining draft and focus. |

Root's native interaction check pasted a synthetic draft, collapsed and expanded the sidebar, and observed the same focused field and draft throughout. The synthetic draft was then cleared through the UI, leaving Send disabled. No message was submitted and existing history was not cleared.

Native screenshot scope is the filled default-size conversation only. Empty-state centering is source-reviewed, not natively captured; minimum-window layout, empty-to-first-send behavior, expanded review/Activity, keyboard navigation and the complete accessibility matrix are not qualified by this checkpoint. Settings and setup retain their separately reviewed implementation; the user's acceptance of the visual direction remains theirs to determine.

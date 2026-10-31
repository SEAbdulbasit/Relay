# Relay design reset — 30 October 2026

A shared native system for the actual macOS app. This revision addresses consistency, alignment and readability across conversation, setup, settings and dictation. The older HTML preview is historical and does not represent this implementation.

## Layout contract

- Neutral charcoal canvas and slightly lifted surfaces. White primary text, readable white secondary text; mint reserved for selected state, readiness and primary actions.
- 28-point content insets. Conversation and composer share one 780-point outer column. Navigation has fixed icon slots and aligned labels; it can be hidden to focus on the conversation.
- 17-point conversation text, 15-point body copy, 14-point secondary explanations. Smaller text is limited to nonessential short metadata.
- A 14-point shared panel corner radius; 18-point composer. Consistent spacing follows 8/12/16/20/24/28-point increments.
- Settings uses a left navigation rail and a single content viewport. Setup uses a stable step rail, scrolling content and a separate action footer.
- Primary actions stay visible. Long technical details use disclosures. Permission, download and submission consequences remain beside the relevant action.
- No artificial delay or decorative animation in typing, navigation or keyboard actions. Press feedback respects Reduce Motion. No inference, capture, download or permission request starts from visual navigation alone.

## Native review checklist

Check the actual packaged app: conversation/composer left and right alignment; expanded and collapsed navigation; Settings Model/Access/Voice/Knowledge/Memory; setup progress and footer; text wrapping; inactive/disabled controls; dictation transcript and action footer without starting capture. Preserve existing drafts/history and avoid real external actions during visual qualification.

## Review results

The first packaged native review confirmed shared chat/composer edges and readable Model/Voice settings. Critique found and corrected a wrapped sidebar clear label, an icon that implied an unsupported side inspector, duplicated readiness copy, and mixed native/custom button heights. Primary and secondary buttons now share a 36-point minimum height. Main/setup wordmarks use the same header centerline. Navigation remains collapsible and does not introduce fake conversation history.

The regression suite passed 362 tests in 56 suites (4.840 seconds; `/tmp/relay-design-reset-tests.log`). These are functional regressions, not a visual-usability score. No microphone recording, external application action, model download, permission change or conversation clearing was performed for this visual review.

## Superseding direction: familiar conversational interface

The user rejected the first reset and explicitly requested a ChatGPT-like interface. The shipping development build now uses a quiet224pt sidebar, neutral#212121 canvas/#171717navigation/#303030composer, borderless Relay/model header,17pt conversation text, right-aligned gray user bubbles and unboxed assistant responses. Prominent timestamps, WORKSPACE heading, readiness rail card, starter task cards and composer readiness/Return hints were removed. Empty chat uses a centered “What can I help with?” and composer block; an active conversation anchors the same composer at the bottom, preserving its structural identity and draft binding. No fake conversation history or archive behavior was added. Clear remains explicitly labeled as clearing the current chat.

Final build and strict development signature verification passed (`/tmp/relay-chat-layout-build.log`).362tests in56suites passed5.828seconds (`/tmp/relay-chat-layout-tests.log`). The actual native conversation is captured in `planning/chat-interface-conversation.png`. Existing history and the empty draft were preserved. The centered empty state is source-reviewed, not natively captured; minimum-window and first-send focus transition remain unqualified. The latest app observed Accessibility as unavailable after ad-hoc replacement; no permissions were changed for this visual task.

Native interaction follow-up: a synthetic draft survived sidebar collapse and expansion with field focus intact. The test draft was then removed through the UI; Send was disabled again. No message was submitted. Independent critique found no blocking issue in the filled conversation capture at1080×790; this does not qualify empty-state centering, minimum-size layout or every active review state.

# Sentient OS — source-grounded design reference

29 October 2026 · Inspected local source at commit `f064441a6d4309b7ae810de08e27b15e688f9a0b`. No downloaded application was built or run. These are implementation observations, not a rendered-screen review.

## What the actual interface is

**A dark spatial canvas, not a sidebar dashboard.** `Theme.swift:13–27` defines black background, cool graphite panel, white-at-5% elevation, white-at-9% strokes and soft violet accents. `SidekickStyle.swift:12–18` narrows the chat identity to neutral glass, near-white ink and black; color appears as localized illumination rather than a tinted reading surface. Its material implementation uses native interactive glass when available and otherwise ultra-thin material with a black overlay, with opaque/increased-contrast alternatives (`SidekickStyle.swift:35–60`).

**A quiet top navigation strip.** Home mounts a small mark and a 13.5pt semibold wordmark, an overview dock, then search/clear in conversation, Analysis, Knowledge and Settings. Outer margins are 30pt horizontally and 18pt at top (`HomeView.swift:385–429`). There is no permanent Home/Activity/Memory/Settings left rail in this Home implementation. Knowledge can have its own panel; that does not make Home a sidebar layout.

**Two related surfaces: overview and conversation.** The home canvas layers atmosphere, overview cards, conversation transcript, bottom dock and top chrome (`HomeView.swift:114–184`). It keeps the transcript mounted, controlling visibility/hit testing rather than replacing the entire composition. Before personal setup, Sidekick is the primary workspace with optional setup beside it (`HomeView.swift:14–17`, `170–181`); after setup, proactive cards can occupy the overview. The card layout uses a 24pt gap, two columns below 1180pt and up to three above, with 240–400pt card widths; short windows page rather than crush the cards (`SidekickOverviewLayout.swift:4–49`). These are real source states, not one universal screenshot.

**The composer anchors the floor.** The bottom dock centers a composer with a 744pt maximum width, 38pt outer horizontal inset and 14pt bottom inset; a small trust line sits below (`HomeView.swift:999–1025`). The composer itself uses a 15pt system field, one to five lines, 17pt internal padding and 18pt continuous glass corners. Its send control is a 36pt circle, near-white when enabled, with a small localized spectrum halo. During a run, a similarly sized neutral Stop replaces send (`SidekickComposer.swift:64–109`, `129–133`). It is not a green rectangular submit button on a large white form.

**Conversation hierarchy comes from alignment and restraint.** Transcript width is capped at 800pt with 28pt side padding; rows are separated by 18pt (`SidekickTranscript.swift:83`, `135–136`). User text sits in a subtle dark rounded bubble, inset from the left by at least 58pt; assistant Markdown is directly on the canvas, without a matching large card or repeated colored avatar. User bubble radius is 18pt, fill white 7.5%, stroke white 7.5%; a reserved control gutter prevents hover controls shifting the text (`SidekickTranscript.swift:305–358`). Empty chat uses a 32pt illuminated mark, 23pt medium heading and 13pt supporting copy (`98–102`).

**Activity is a low-emphasis inline disclosure.** Work is associated with transcript tasks. It loads only when expanded, retains bounded rows and freezes reader position when the user takes control (`SidekickWorkDisclosure.swift:5–35`, `54–78`, `97–99`). Labels distinguish Working, Waiting, Stopped, Couldn’t finish and elapsed time (`SidekickTranscriptLayout.swift:55–75`). This differs from making a separate activity dashboard the main product surface.

## Type, palette and atmosphere

- System type is the core face. `Theme.swift:128–135` implements medium-weight display text with no extra manual tracking; the source explicitly relies on SF optical sizing. MonoCaps is a separate uppercase, tracked monospace annotation voice (`82–103`). Serif is reserved for specific note/letter contexts, not general chat (`5–8`).
- Editorial tokens include card `#0c0c0f`, primary status ink `#e9e7ee`, body `#9b9aa0`, brighter ink `#cfcdd6`, and purpose-specific green/amber/red (`Theme.swift:64–78`). Green is not the general surface color.
- Atmosphere is black beneath a crown of blurred spectrum light at the upper edge, cached neutral grain, and a smaller light echo near the composer (`SidekickStyle.swift:96–174`). The source pauses movement during inactive/reduced-motion/low-power conditions; Home also gates it while selecting or scrolling (`HomeView.swift:119–121`). It explicitly avoids a full-window gradient fill (`SidekickStyle.swift:146–149`).

## Why the Relay draft diverged

| Before — our draft | After — direction supported by this reference | Why |
| --- | --- | --- |
| Warm off-white canvas, sage navigation and green primary controls | Black/cool-neutral canvas with restrained white ink and localized spectral light | We invented a different palette before inspecting the requested reference. |
| Permanent 207pt navigation rail and breadcrumb dashboard chrome | Quiet top strip, centered conversation and a floor-mounted composer | The reference allocates attention to the task/conversation rather than persistent navigation furniture. |
| Repeated speaker labels and bordered content cards | Subtle user bubble; assistant prose on the canvas; secondary controls in reserved gutters | The reference uses asymmetric message styling and removes repetitive decoration. |
| Large promotional greeting/illustration above a form | Small illuminated mark, restrained empty state and composer anchored consistently | The reference treats assistant readiness as the workspace, not a landing-page pitch. |
| Generic rounded panels with warm colored fills | Neutral material/glass, very thin strokes, clear depth only where interactive | Surface hierarchy comes from light and material rather than many boxed sections. |

This is a visual reference, not permission to inherit Sentient's product features. Its proactive scheduling, personal setup, hosted-provider integration and knowledge ingestion do not belong in Relay merely because the source contains them. The user's current direction remains conversation-first, local models only, with user-requested internet tasks allowed.

## Exact inspected files

- [Theme.swift](</tmp/relay-sentient-reference/Sentient OS macOS/Views/Theme.swift:13>)
- [HomeView.swift](</tmp/relay-sentient-reference/Sentient OS macOS/Views/HomeView.swift:114>)
- [SidekickStyle.swift](</tmp/relay-sentient-reference/Sentient OS macOS/Views/Sidekick/SidekickStyle.swift:12>)
- [SidekickComposer.swift](</tmp/relay-sentient-reference/Sentient OS macOS/Views/Sidekick/SidekickComposer.swift:64>)
- [SidekickTranscript.swift](</tmp/relay-sentient-reference/Sentient OS macOS/Views/Sidekick/SidekickTranscript.swift:305>)
- [SidekickTranscriptLayout.swift](</tmp/relay-sentient-reference/Sentient OS macOS/Views/Sidekick/SidekickTranscriptLayout.swift:55>)
- [SidekickWorkDisclosure.swift](</tmp/relay-sentient-reference/Sentient OS macOS/Views/Sidekick/SidekickWorkDisclosure.swift:54>)
- [SidekickOverviewLayout.swift](</tmp/relay-sentient-reference/Sentient OS macOS/Views/Sidekick/SidekickOverviewLayout.swift:20>)

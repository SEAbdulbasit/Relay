# Independent design audit after Antigravity

31 October 2026. Read-only review of the current SwiftUI source and Antigravity's saved AppKit renders. This audit is independent of the generator's completion claims. Root is inspecting the live app separately. No source edits, build, microphone recording, permission changes or user-data deletion performed by this reviewer.

## Verdict

The dark palette, white text and thin borders can be retained. The major problem is that the interface presents fabricated demonstrations as the user's real personal context and verified actions. That is more serious than spacing polish. The experience should be simplified around actual chat, selected sources and verifiable task results; the existing visual language does not require a wholesale replacement.

## Findings and corrections

| Before | After | Why |
| --- | --- | --- |
| P0 — `MainView.defaultBriefingItems` shows Carl's email, Canva renewal, New York train, Denver receipts and Hawaii group messages as real personal events. | Remove seeded personal tasks from the default workspace. Show only genuine source-backed suggestions or a truthful empty state. Explicit opt-in examples may exist separately and must be labeled. | The app has not read these accounts or established these events. Users reasonably interpret the cards as their data. |
| P0 — `thingsReadCount` returns `max(197, records.count * 18 + 197)`. | Display the actual indexed-source count, or omit the counter. | Fabricated progress creates a false impression of ingestion and personalization. |
| P0 — `runCardExecution` sleeps through plan lines, then sets `cardCompleted`; the card says “DONE · VERIFIED BY CRITIC.” | Remove simulated execution states from the shipped workspace. Bind status only to actual store task/evidence results; preparing a draft must say “Draft ready,” never “verified.” | No tool, model or independent check is executed by that timer. |
| P0 — Double Tap invents Northstar context if selection capture fails and returns canned Carl/Sarah/Alex replies before attempting to paste them. | Disable/remove the production trigger until it uses actual captured context and real local inference, stages an unsent draft, and exposes the failure when capture is unavailable. | The current button looks like a useful task while introducing invented facts into another app. |
| P1 — `SkyGraph.build` inserts a synthetic personal graph, `KnowledgeVaultManager` writes seeded Northstar files and root-note rendering substitutes hardcoded personal prose. | Build the graph from real selected/indexed records and explicit user-created notes. Preserve/display the real root-note text. Start empty and never silently remove existing user files during cleanup. | The attractive graph currently manufactures knowledge and conflates sample content with approved sources. |
| P1 — New Note inserts links to fictitious Northstar/Alex notes. | Start with an untitled heading and an empty body. | An actual user's note should not inherit demonstration people/projects. |
| P1 — Header back/Home calls `clearConversation()` when already in chat (`MainView.swift:279`). | Home changes the visible workspace without deleting conversation. Keep explicit Clear chat separate with an accurate label. | Navigation must not destroy history. |
| P1 — Settings advertises single-tap open and ≥250ms push-to-talk even though those handlers were removed. | Describe only the implemented trigger, or remove the whole unused setting group. | Instructions must match behavior, especially microphone activation. |
| P1 — Settings says “100% Offline” and “zero network connectivity.” | Say “Model inference runs on this Mac”; separately state that setup downloads and user-requested browser tasks can use internet. | Local inference does not mean the entire application makes no network requests. |
| P1 — Three-column Knowledge pins a 215pt tree and 390pt reader before separators/padding; narrow-window behavior is unverified. | Use adaptive columns or a source list + reader as default, with graph as an optional view. | A graph should not make the useful reader collapse at smaller sizes. |
| P1 — Essential main-card captions/actions use 9–12.5pt text and line limits; welcome screenshot ellipsizes hardware guidance. | Use 14–15pt explanations, clear action targets and wrapping for readiness/errors. Do not force all content into a fixed non-scrolling stage. | “Fits the window” must not be achieved by shrinking or truncating important information. |
| P2 — Analysis, Double Tap, spinning logo, envelope/gift, graph and multi-agent theater compete for attention. | Keep Chat, Sources and Settings easy to find. Retain subtle spectrum light/mark as identity; remove promotional or simulated mechanisms from the default workflow. | Every visible control should serve an implemented user task rather than demonstrate architecture. |
| P2 — Constellation runs a 60fps TimelineView continuously without a local Reduce Motion/inactive gate. | Pause while inactive and reduce motion when requested; render statically when no interaction requires motion. | A knowledge reader should not consume continuous rendering or distract users for decoration. |
| P2 — Permission setup renders very tall mostly empty cards in saved snapshots, while footer buttons are visually faint. | Let content determine card height and keep the actionable permission/check states near their explanations. Distinguish intentionally disabled controls from low-contrast enabled controls. | Visual hierarchy should point to the next useful action rather than blank decoration. |

## Retain

Retain the neutral dark canvas, readable white headings, localized color accents, clear source/index separation in Settings, explicit permission status, ordinary chat composer and evidence disclosures. Keep voice as an explicit optional feature unless the user clarifies that all audio controls should be removed; “no adudi” is not enough to infer that destructive scope.

## Native visual evidence reviewed

Saved AppKit screenshots under `/Users/abdulbasit/.gemini/antigravity/brain/7a585575-86ad-4258-b597-6d417297c4eb/`: `macos_main_briefing_v2.png`, `macos_knowledge_constellation_v2.png`, `macos_onboarding_welcome_v2.png`, `macos_onboarding_permissions_v2.png`. These confirm the presence of seeded personal cards, fabricated 197 counter, dense three-pane knowledge, onboarding theater and truncated hardware guidance. They are generator-produced offscreen renders, not evidence of live interaction success, microphone behavior, real browser operation, accessibility quality or minimum-window support.

## Finish gate for the cleanup

Review real empty and populated chat; sidebar/workspace navigation without data loss; actual source-empty and populated states; Settings Model/Access/Voice/Knowledge/Memory; all onboarding steps; long model/source names and errors; compact window; keyboard focus/Return/Escape and draft preservation; reduced motion. Search production UI for remaining fictional people/trips, fake counters, timer-based verified badges and claims of unseen data. Use isolated fixtures for screenshot tests so audits do not write example data into the user's actual vault. Automated component tests do not establish Sentient feature parity.

## Focused implementation by this reviewer

At the parent's request, edited only `KnowledgeView.swift` and `SentientConstellationView.swift` after completing the independent read-only findings. Removed seeded graph content, fictional root-note substitution, invented wikilink chains and new-note links to fictional people. Empty input now produces no graph nodes and a choose/index empty state. Populated graphs contain only current index records, explicit session notes and derived group/overview nodes; literal wikilinks resolve only when their title is unique. Indexed excerpts and generated overview are read-only. The reader keeps two panes in narrower layouts and shows the optional third graph pane only at 900 pt or wider. Graph drawing pauses for Reduce Motion/inactive scene and otherwise uses 30 fps. No persisted note files were changed or deleted. Swift frontend syntax parsing passed; full build and native review belong to the parent integration gate.


## Integrated cleanup

Removed production seeded briefings, the fabricated count of 197, simulated card execution/verified states, gift-letter controls, Analysis simulation and Double Tap entrypoints from MainView. The visible workspace now uses actual conversation, actual index counts and real Activity results. Returning from Knowledge preserves chat. Removed automatic main-window notch-monitor installation and the unsupported Sidekick/DoubleTap Settings section. Corrected Settings networking language and raised body text to17pt/captions14pt. The actual explicit microphone and read-aloud features remain; the ambiguous earlier wording was not treated as permission to remove working audio features.

Notch no longer creates example personal notes or fabricates replies/selected context, captures the screen automatically, or pastes canned content. Legacy unsupported draft requests leave the user's draft intact and explain unavailability. Existing disk notes were preserved.

Onboarding now explains setup without Northstar/overnight simulation or forced non-scrolling layouts. Actual permissions/model state and all five setup stages remain.

The integrated Swift suite passed **396 tests in 63 suites** in 5.051 seconds (`/tmp/relay-independent-audit-tests.log`), including new knowledge-graph and no-fabricated-draft/vault regressions. Optional hardware/model cases were not enabled by this run; this count is not real browser, microphone or product-parity qualification. Native review and final build evidence follow below.

Separate issues identified but not changed under this design cleanup: the backend's new automatic standard-folder grants need a permissions-policy review; the companion website contains unsupported marketing/distribution/performance claims; legacy seeded files already on disk need a deliberate user-visible migration rather than silent deletion.

### Follow-up: source reader scope

Removed New Note, Edit/Save and legacy-vault Show in Finder from the main Knowledge workspace. The previous view-local note counter could reuse a filename across sessions, and its editor did not reload persisted notes; these are not qualified production controls. The workspace now reads actual indexed excerpts only, and Full Constellation is disabled when none exist. Settings' explicit legacy-vault reveal remains; no existing notes/files were edited or deleted. Removed unreachable view-local note writing/state/helper code. Syntax parsing passed; integration build/native review remain with the parent.

## Independent review of cleanup captures

Reviewed the parent's `planning/independent-audit-{home,knowledge,model,access,access-lower,source-settings,memory}.png` native captures. At those captured sizes, no material alignment/clipping blocker is evident in the home, source-empty workspace, Model, lower Access, source settings or Memory. Scrollable lower-card continuation is expected. The home intentionally keeps a spacious empty state; fabricated cards and counts are gone. One enabled-state affordance remains: the empty Knowledge view's Full Constellation control looks active despite being disabled; omit or visibly dim it. The rightmost end of the Global Stop explanation in `access.png` should receive a final native wrap check. This review does not establish compact-window support, populated graph interaction, Voice/onboarding states or general task reliability. Root is separately correcting remaining source-settings copy overclaims.

### Voice and all five setup states

Independently inspected `independent-audit-voice.png` and `independent-audit-setup-{welcome,privacy,model,access,final}.png`. No material clipping or alignment blocker is visible at their captured sizes. Voice's toggle and text are aligned and controls remain explicit. Setup now has focused welcome/privacy/model/access/final content and reachable footer actions. The final screen separates a loaded model from unavailable computer control; privacy copy distinguishes on-device inference from network-dependent downloads/websites. Fictional personal demonstrations are absent. Root reports these states were visited without downloads, microphone use or permission changes and then exited through Set up later, preserving the user's chat. These captures qualify visual presentation only, not audio/permission/download execution, task success or compact-window behavior.


### Final visual corrections

The shared press style now dims disabled buttons and removes their press motion. Source settings now says “Local index” and accurately describes indexing without claiming zero OS/cloud synchronization or Markdown-only storage. The Global Stop explanation was shortened for clear wrapping. These are visual/copy corrections after the passing functional suite. Final packaging/signature result and the scoped native check are recorded below.

## Final package and native verification

The final development package built and passed the script's strict signature verification (`/tmp/relay-independent-audit-build.log`). Relaunch showed the existing user's “hi” conversation preserved, the real local-model/tool-call readiness probe passed, and an empty draft with Send disabled. Knowledge showed zero actual indexed sources, no fabricated people/events, no New Note/Edit controls and a visibly dimmed disabled graph button. Returning to chat preserved that conversation. Final image: `planning/independent-audit-knowledge-final.png`.

Native visual review covered the home/conversation, empty Knowledge, all five Settings tabs (including lower Access content) and all five onboarding steps. Setup was exited without seeding a task, downloading, requesting permissions or using audio. Existing disk notes and conversation were not cleared. Optional real microphone/browser/model stress and minimum800×620 layout are not qualified by this audit. The final copy/disabled-style changes do not alter the source-graph/no-fabricated-draft logic covered by the396-test suite.

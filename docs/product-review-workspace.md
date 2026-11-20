# Relay workspace review — 20 November 2026

Scope: `MainView.swift`, `ActivityPresentation.swift`, and workspace entry points into the existing store. This review separates source-confirmed behavior from runtime verification. Existing uncommitted implementation was preserved.

## Assessment and direction

Relay already has a substantive native workspace: saved conversations, reply references, Markdown/code/table rendering, tool activity, approval evidence, file and visual context, model selection, dictation, and task continuation. The biggest quality problem in this area was trust: UI presentation inferred completion and computer execution from insufficient evidence. Secondary problems were compact-window navigation and controls hidden from keyboard users.

Keep the 760-point conversation column, native typography and restrained surfaces. Present the request and its result first; explain progress with concrete phase text; show verified success only when the tool result explicitly says `verified`. Product-specific interactive examples must be visibly distinguishable from the user's real data. These decisions come from Relay's actual implementation; reference-product study is recorded by the coordinating review.

## Findings and implemented corrections

| Severity / status | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| High, confirmed and fixed | `activityPanel` plan rows | Every planned step gained a green completion check whenever `isRunning` became false, including failure or stop | Neutral planned-step markers, explicit note that individual step completion is not tracked | Avoids asserting work was performed without evidence |
| High, confirmed and fixed | `activityPanel` status | “Executing live steps on your Mac” covered planning and review waits | Phase-specific status; stopped, failed and needs-input phases remain visible | Users can distinguish reasoning, tools, approval and interruption |
| High, confirmed and fixed | `conversationDock` recovery | “Inspect & resume” resumed immediately; failed tasks had no dedicated recovery strip | Separate Inspect activity and Resume/Continue actions, with explicit stopped/failed/input copy and unchanged backend continuation guards | Actions now describe their actual effect and leave room to inspect partial changes |
| Medium, confirmed and fixed | `ActivityPresentation` | Uncertain effects looked like neutral unknown statuses | Warning icon and explicit inspection copy, without falsely labeling them verified or failed | Communicates partial or uncertain outcomes without color alone |
| Medium, confirmed and fixed | Header/sidebar/shortcuts | Under 860 points the sidebar was removed while its toggle still reported “Shown” | Compact popover exposes History and Activity through the same button, notification, palette and shortcut | Restores navigation at narrow widths |
| Medium, confirmed and fixed | Transcript and history row controls | Message actions and delete affordances depended on pointer hover; invisible buttons could participate in keyboard focus | Message actions and thread delete buttons remain visible and hit-testable | Makes available actions discoverable with keyboard and assistive tools |
| Medium, confirmed and fixed | Thread selection / transcript scroll | New thread could inherit “reading earlier content” follow state | Reset follow state and scroll on active-thread changes; retain existing in-thread manual-scroll behavior | Prevents stale scroll state from concealing the selected thread's newest content |
| Medium, confirmed and fixed | Welcome | “Relay is ready” appeared even without an available model | Readiness-dependent heading and next-step copy | Does not promise a ready model during setup |
| Medium, confirmed and fixed | Showcase previews | Tiny “interactive preview” label did not explicitly distinguish fabricated example data | Readable Example label and explicit statement that examples do not read apps or run tasks | Prevents illustrative fixtures being mistaken for real autonomous results |
| Medium, opportunity implemented | Header/composer | Text-heavy toolbar stayed full width without sidebar, even on compact windows | Compact toolbar below 1000 points; icon header actions below 760 with accessible labels | Reduces avoidable horizontal pressure |
| Low, confirmed and fixed | Composer/history/showcase motion | Several transitions ignored reduced-motion preferences | Conditional animations for focus/drop, history expansion, constellation and autopilot examples | Respects system interaction preferences |

## Coverage checklist

`Source reviewed` means code paths were inspected, not that a successful real integration run occurred. The coordinating agent owns the running-app checks and integrated build.

| Area / state | Coverage and outcome |
| --- | --- |
| Empty workspace, model unready/ready, starter prompts | Source reviewed; readiness copy corrected; prompts still populate a draft through the existing action |
| Home feature deck / four expanded previews | Source reviewed; example disclosure added; live configuration and task buttons retained |
| Saved history, search, grouped/pinned threads | Source reviewed; compact navigation restored |
| Thread rename, delete, clear history / clear conversation | Source reviewed; existing confirmation dialogs and backend actions retained; delete affordance made visible |
| Active thread, reply references, selected quote, edit/branch, regenerate | Source reviewed; existing store-owned implementations retained |
| Long Markdown/code/table content and artifact links | Source reviewed; existing wrap/scroll and code-copy behavior retained; 760-point reading width retained |
| Manual transcript scrolling, latest-message return, thread switching | Source reviewed; thread-reset defect corrected; existing manual-follow logic retained |
| Planning, acting, awaiting review, stopped, failed, needs input, completed | Source reviewed; task presentation now models each phase explicitly |
| Tool verified/failure/uncertain/observed/stop statuses | Source reviewed; uncertain effect warning added; verified-only success distinction retained |
| Multi-agent plan and role badge | Source reviewed; false step completion removed; role information retained |
| Review card: action details, structured mail evidence, visual evidence, sharing | Source reviewed; evidence scroll region, explicit action approval and decline remain intact |
| File drop/attach, folder grant, window/image context, clipboard image | Source reviewed; existing capability/permission routing retained |
| Model picker and provider sharing hints | Source reviewed; unchanged backend model routing |
| Dictation/read-aloud states and cancel controls | Source reviewed; stop controls preserved |
| Command palette, conversation search, copy/export, setup entry | Source reviewed; compact sidebar command corrected; existing keyboard selection retained |
| Header permissions, errors, selected-text notice, journal/storage notice | Source reviewed; existing real error text and dismiss paths retained |
| Knowledge page / Morning Brief / settings sheets | Entry points reviewed; destination details owned by other review lanes |
| Resize | Source-level layout pass at compact/regular breakpoints; actual live-window inspection owned by coordinator |
| Keyboard and VoiceOver | Source-level affordance pass; full screen-reader/focus traversal not performed in this lane |
| Offline/provider failure, native action permission, actual stop/resume, persistence across restart | Backend paths inspected; real integration runs not performed in this lane |

## Validation

- Swift frontend parsing passed for `MainView.swift`, `ActivityPresentation.swift`, and `ActivityPresentationTests.swift` after the changes.
- Added targeted presentation tests for interrupted run phases, planning vs. tool use, and uncertain-effect attention semantics. Integrated compilation and execution are owned by the coordinating agent to avoid concurrent SwiftPM builds.
- No store policy, permission boundary, tool dispatcher or execution capability was changed.

## Remaining limitations and follow-up

- Per-step execution completion is not provided by the store. A future backend step-progress model could support checked individual steps; the interface now honestly shows a plan instead.
- Palette Knowledge-note results route to Knowledge rather than selecting a concrete note. Implementing direct note selection requires a shared destination model and remains a navigation opportunity.
- Command palette search scans complete saved message content synchronously. The source alone does not establish a performance defect; profile with a large real archive before introducing indexing or background state.
- Some examples use fixed horizontal layouts and small metadata. Representative short-height/compact rendering still needs the coordinating visual pass; no unobserved visual pass is claimed here.
- Native tools and external model behaviors require permission/account-dependent integration verification. Source checks and presentation tests cannot establish end-to-end success.

Independent-review follow-up: the transcript status now uses the same provider-neutral phase wording as Activity; its combined accessibility label preserves the actual status text. The complete plan is inside the Activity scroll region, so a long plan cannot consume the entire compact dock above the tool list. Swift frontend parsing passed again after these corrections.

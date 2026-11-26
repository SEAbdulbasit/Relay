# Relay and upstream project: current design and task audit

Date: 1 November 2026. Baseline observations; no source changes or fresh automated test run in this audit.

## Conclusion

Relay does **not yet match Reference on this small task set**. After permission repair, both verified Calculator running. Relay verified the Finder query, while Reference additionally reported the visible matching file. Reference read the public browser page accurately; Relay navigated successfully but its reader stopped because browser state was ambiguous. These three trials do not establish overall feature parity or reliability.

Relay 0.1.0 uses local Gemma 4 E2B through LiteRT-LM. Installed upstream project 2.7.4 (20) was configured to use connected ChatGPT for actions, with on-device Gemma 4 E4B also listed. These are materially different inference configurations; no latency comparison is justified by this trial.

## Live task results

| Task | Relay | upstream project |
|---|---|---|
| Open Calculator; verify running; do not type | PASS. Launch evidence returned a running Calculator process; independent app inventory confirmed it. This verifies launch, not clicking or typing. | PASS after setup. Reported Calculator running; independent app inventory confirmed it. Activity showed looking at Calculator. |
| Search sf.webm in Finder's visible search field; do not open or modify files | Query verification PASS after refreshing current-build access. AX evidence matched query and results mode; explicitly did not prove a matching file exists. Final chat omitted this distinction, leaving it in expanded evidence. | PASS. Reported query and matching file separately. Independent Finder AX inspection confirmed both. |
| Open example.com in Safari; read its heading; no other tabs or forms | PARTIAL. Navigation verified. After permission repair, reading failed with “browser state was ambiguous”; no heading fabricated. | PASS. Reported no visible main heading and page title “Example Domain”. Independent public-page screenshot and AX state support that distinction. |

Initial trials were permission-blocked. The table records the subsequent successful or failed outcomes, not just the first attempt. Finder already contained Reference's query when Relay retried, so Relay's retry establishes correct final-state verification but is not an isolated fresh-search test. Safari was already on the requested public page for these navigation trials. No speed ranking is made. Reference displayed 18 seconds for Calculator, 27 for Finder and 25 for the browser task; these UI values are not matched performance measurements.

Exact prompts:

1. `Open Calculator. Do not type into it or change any calculation. Confirm only after checking whether Calculator is running.`
2. `Open Finder and search for sf.webm using Finder’s visible search field. Do not open, move, rename or delete any files. Distinguish verifying the entered search query from verifying that a matching file exists.`
3. `Open https://example.com in Safari and report the page’s main heading after reading the page. Do not inspect any other tabs, sign in, submit forms, or change files.`

Evidence screenshots in this directory:

- reference-comparison-permission-block.png
- comparison-relay-calculator.png
- comparison-relay-finder-block.png
- comparison-safari-public-page.png
- comparison-relay-browser-partial.png
- comparison-relay-model-settings.png
- comparison-relay-browser-ambiguous.png
- comparison-reference-completed.png

## Design findings

The current runtime has changed substantially since the older neutral-theme audits. It shows a glowing welcome illustration, colored role cards, compact task chips and a luminous composer. Earlier screenshots must not be treated as evidence for this version.

### Highest priority

1. **Incorrect Stop instruction.** OnboardingView.swift teaches Command-period as a global Stop action. GlobalStopShortcut.swift implements optional Command-Shift-Escape. Show the actual shortcut and whether it is enabled; distinguish window-local cancellation from global cancellation.
2. **Readiness does not equal desktop readiness.** Local model readiness can be green while required Accessibility access is missing. Show model and computer-control readiness separately, with a direct recovery action before desktop requests.
3. **Offline claims contradict behavior.** Runtime says “100% Offline”; onboarding uses “Air-Gapped Local Runtime”. Downloads and requested browser navigation can use the network. Use “Local inference” and clearly describe optional network activity.
4. **Activity layout has a source-confirmed width risk.** MainView.swift uses a 720-point content column plus a 310-point activity panel starting at 960 points. Their combined minimum exceeds that threshold before other spacing. Verify at 960, 1000 and 1100 points; use a flexible column or a drawer. This has not yet been reproduced through native resizing.

### Interaction and consistency

- Starter chips are visibly truncated. Use fewer fully readable suggestions and a wrapping layout.
- “Summarize Files” currently drafts a question asking which files are available. Match the label and action, and respect connected-folder readiness.
- Starter callbacks overwrite an existing draft. Preserve draft text or offer an explicit replacement.
- Executor / Navigator / Planner labels expose implementation roles before explaining a useful task. Prefer task labels such as “Open an app”, “Find a file”, and “Read a page”.
- Header leading/trailing controls can compete with an independently centered segment. Check narrow widths and use adaptive layout.
- Onboarding uses a dense non-scrolling stage. Add a scroll fallback with stable navigation and verify at the minimum supported height.
- Static green checks and verification claims in the onboarding preview resemble real measured outcomes. Label it as an example and keep actual readiness visibly separate.
- Keep onboarding, chat, permissions, model download and settings on the same typography, spacing, surface and control system. Reduce decorative glow and tiny tracked captions that compete with task text.

Source findings were independently reviewed by a read-only design-review agent. They are not live task capability evidence.

## Permission setup and remaining comparison

The user explicitly approved Reference Accessibility and Screen Recording setup and refreshing Relay Accessibility access. After the user paused interaction and authenticated directly, macOS showed Reference control and Screen Recording access enabled. Relay's existing control switch was enabled, but its in-process trust check still failed after an off/on refresh. Removing only Relay's stale entry and re-adding Relay.app from the current build directory made its own “Check again” report “Accessibility allowed”. No other app permission was changed. No personal analysis, source connection, microphone capture or background access was started.

Relay's build is ad hoc signed with no TeamIdentifier. A stale entry after rebuilding is a plausible explanation for the mismatch, not a proven diagnosis. Stable signing and explicit current-build permission recovery remain release concerns.

### Product implications

- Browser observation must resolve the intended browser/window/tab deterministically or ask a precise recovery question. The current generic ambiguous-state failure prevents a basic page-reading task that Reference completed.
- Relay should surface the distinction between query entered and file found in its normal reply, not only expanded evidence.
- Readiness should cover current process permissions, not merely local-model readiness or the macOS switch.
- Reference's inline, collapsible activity keeps progress near the answer. Relay's permanently occupied activity column and raw role language create more visual competition; use concise task progress with optional detail.

Remaining qualification work:

1. Test Relay permission recovery after a fresh build/relaunch without disturbing other apps' grants.
2. Repeat with controlled fresh app state, clearing only the test query and using an isolated public page fixture. Test multiple tabs/windows explicitly.
3. Add a disposable form fixture: Unicode input, focus recovery, disabled controls, scrolling, and read-back verification.
4. Test cancellation during an action, missing permission recovery, ambiguous app names and unavailable targets.
5. Record outcome accuracy separately from task completion. Never count a claimed action without independent visible evidence.
6. Compare latency only with explicit start/end boundaries and matched task state; disclose local versus hosted inference.

Do not claim Gmail, arbitrary-app compatibility, voice readiness or complete Reference feature parity from these three tasks.

## Implementation follow-up

Implemented after the baseline comparison:

- Safari HTTPS window recognition, hidden-tab single-document qualification, keyboard focus in browser chrome, and document-local AXDescription title fallback. Conflicting documents and real ambiguous tabs remain rejected.
- Finder query and visible exact-result evidence separated; bounded result observation and qualified IconView/ListView list handling. Absence remains unverified.
- agent-desktop delivered-versus-verified disposition respected with exact text-value readback required.
- Bounded subprocess output, timeout, cancellation and forced termination fallback; nonzero exits cannot remain successful envelopes. Arbitrary helper descendants remain a separate supervision concern.
- Explicit checkpoint unlock before close avoids inherited-descriptor lock retention.
- Flexible chat/composer, adaptive suggestions, preserved drafts, quieter decoration, accurate local-inference wording, scrollable onboarding, correct optional global Stop instruction and actual permission warning.

Automated verification reached 426 tests across70 suites passing before the final Finder container extension; additional targeted regression and live tests must be recorded separately. The last earlier live attempts still failed Safari title qualification and did not positively identify Finder results; do not mistake the source fixes for completed live qualification.

Source studies: [Reference](reference-source-gap-study.md) and [agent-desktop](agent-desktop-integration-study.md). These include pinned reference commits, concrete code paths and prioritized further work. Broad superiority over Reference is not established.

### Latest verification status

Full native suite: **428 tests in70 suites passed**, `/tmp/relay-complete-tests.log`. A sandboxed first run failed native OCR/local-server operations; the unrestricted native run is the reported result.

Live retesting confirmed Calculator running again and Finder query verification after permission refresh. Browser reading itself now succeeds, but the first successful read produced an incorrect model answer calling the page title a heading. The subsequent source correction now separates observed AX headings from title metadata; 10 reader tests and the full suite pass. A fresh live answer with that last correction remains required.

Finder exact-match verification did not report a matching file in the last Relay response. Independent Finder inspection was denied by the computer-use tool (“Computer Use was not approved to use Finder”). Therefore neither presence nor absence is independently requalified in this final iteration. Broad parity remains unproven.

| Before | After | Why |
|---|---|---|
| Fixed content beside activity | Flexible content and later side-panel breakpoint | Avoid overflow |
| Dense suggestions and draft replacement | Wrapping suggestions disabled for existing drafts | Readability and input preservation |
| Different onboarding behavior and inaccurate copy | Scroll fallback, example labels, truthful local/network wording | Consistency and clear expectations |
| Wrong global Stop instruction | Actual optional shortcut and cancellation limits | Accurate control |
| Model-only readiness | Separate current-process Mac permission warning | Prevent false desktop readiness |

Native minimum-size visual qualification remains open; source review is not a substitute for that check.

### Live continuation: heading correction qualified

After relaunching the final build and refreshing the already-approved current-build access, Relay answered the exact browser prompt: “I was unable to find a distinct main heading in the accessible content of the page. The page title is ‘Example Domain’.” Read webpage reported checked. Independent Safari AX inspection confirmed the requested URL, page title and accessible content without a heading node. Screenshot: comparison-relay-browser-grounded.png. This matches Reference's observed answer on this task.

The exact Finder task was rerun: query entered/verified, matching file explicitly unverified. Independent Finder access was denied again by the computer-use tool. Do not call this full Finder result parity. No private file was opened.

Calculator exact prompt also rerun on the final build: Relay answered “Calculator is running”; independent app inventory confirmed com.apple.calculator running. Final task comparison: Calculator PASS, browser accessible-content/title distinction PASS, Finder entered query PASS but matching filename UNVERIFIED.

All five onboarding stages were traversed in the running app: welcome, privacy, model (already installed/ready state), access (granted state), launchpad. Saved final-onboarding-privacy/model/access/launchpad.png. No download was restarted, no new folder granted, no microphone used. Finished with empty draft and retained conversation. This does not qualify active-download/error states or minimum-window resizing.

Screenshot critique found faint onboarding captions/footer and developer-facing demo copy. Follow-up increased these to the shared secondary text color and replaced AX/NSWorkspace/database jargon with plain task steps. Model copy now explicitly distinguishes local inference from requested networking. This is a typography/copy-only change after the live functional tests; no new functional pass is inferred from it.

### Implicit arithmetic-to-Calculator test

Prompt submitted verbatim to Relay: `what is 428x23445555`. Expected product workflow: infer multiplication, open Calculator, enter operands/operator, verify the displayed result, then answer. Correct product: 10,034,697,540.

Relay FAIL: answered that the numbers lacked context and requested clarification; no Calculator action requested. Prior app-launch PASS does not cover implicit tool selection or calculation entry. Reference NOT RUN: computer-use tool denied selecting upstream project. Cannot infer its behavior from prior Calculator launch test.

### Reference arithmetic access restored

upstream project 2.7.5(21) accepted the exact prompt `what is 428x23445555`. UI changed from Starting Sidekick to “Responded in18s” and answered `428 ×23,445,555 =10,034,697,540`. No Calculator/computer-action activity was exposed for this turn; unlike earlier desktop tasks there was no “Worked for…” activity disclosure. This is evidence of correct direct answering, not proof of a Calculator workflow or its internal computation method. Screenshot: comparison-reference-implicit-arithmetic.png. Relay's same-prompt trial previously failed to understand the request.

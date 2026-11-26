# Relay parity verification — 6 November 2026

Tested on an Apple M1 Pro Mac (32 GB, macOS 27.0.1, build 26A434). The installed reference was upstream project 2.7.6 (23). Its configured hosted Sidekick and Relay's embedded Gemma are different model configurations. This report compares observed workflows rather than claiming a model benchmark or complete product parity.

The team inspected the installed reference, exercised its disposable computer-use diagnostic, and checked its earlier Calculator, Finder, Safari and arithmetic work records. See [the reference observations](referenceos-reference-2026-11-06.md) for which scenarios were live, historical, or gated. No personal source ingestion or messaging was used.

## What changed

- Local Double Tap prepares an unsent reply in a supported, focused multiline editor. Relay validates the target, caret and unchanged text before writing, and checks the resulting text. The gesture is opt-in and monitors modifier events only.
- Knowledge can create and edit private Markdown notes, filter note titles, and export individual indexed source excerpts with provenance.
- Model catalog choices are scoped to Relay's model directory and verified by SHA-256 before selection. The pinned LiteRT-LM runtime's GPU speculative decoder is disabled after a teardown crash; CPU MTP and GPU inference remain available.
- Browser choice follows explicit requests and updated constraints. A missing native app cannot silently become unreviewed web navigation. An uncertain navigation is not replayed.
- Finder editing is restricted to the recognized search field in the selected Finder window. Relay no longer uses Delete or Return as part of the search, and reports query entry separately from matching-file evidence.
- Multi-agent execution uses evidence for the current step, stops on declined or uncertain work, and retains checked or late action results without replaying a mutation.
- Settings has a screen capture diagnostic separate from the AX diagnostic. It captures only the bundled fixture's uniquely identified window, checks a synthetic marker, and discards the pixels.

## Acceptance evidence

| Scenario | Result | Evidence |
|---|---|---|
| Fresh onboarding | Passed on AntiGravity's final app build | Five screens opened in an isolated profile. Relay loaded E4B on CPU; the blank launchpad opened an empty workspace without dispatching a task. |
| E4B CPU and GPU | Passed | Native CPU load and tool protocol; GPU switch through Relay's settings; independent fresh-cache GPU tests after disabling MTP. |
| E2B CPU and GPU | Passed in native tests | Native tool calls, readback continuation, exact long Unicode payloads, and clean GPU exits with MTP disabled. |
| Arithmetic | Passed live | Relay's tool receipt and final response both showed 10,034,697,540 for 428 × 23,445,555. |
| Calculator cold launch | Passed live | Calculator was initially absent. After the action, macOS showed `com.apple.calculator` running and Relay reported the verified launch. |
| Finder without AX | Passed live | Isolated app correctly declined the search, did not type or click, and did not claim a file match. |
| Finder with AX | Passed in the production path | Entered and read back `relay-move-source.txt` in the intended Finder window. The visible result had exactly that name. The tracked fixture’s inode, size, modification time and SHA-256 were unchanged. |
| Safari public page | Page and title verified; heading unavailable | Review bound Safari to exactly `https://example.com`. The authorized production reader verified the selected document and title `Example Domain`. Safari exposed no heading to AX; the stricter heading assertion failed. Reference’s prior run made the same title/heading distinction. |
| Chrome loopback | Passed in the production path | Verified exact selected URL, heading and Unicode marker. Editable content was excluded; the independent fixture recorded one GET and zero POSTs. |
| Native Accessibility fixture | Passed | All seven checks passed: observation, Unicode typing and readback, independent single Apply effect, stale and disabled controls, review drift, and queued action invalidation. The agent-desktop backend separately passed its real Unicode and click/readback fixture. The real pointer check passed for both backends and confirmed Stop hid the pointer. |
| Screen capture fixture | Passed in authorized runner; app reported blocked | The real bundled-window capture read its launch marker in memory. The rebuilt app correctly reported its own screen capture grant unavailable without a permission request. |
| Focused Double Tap | Native insertion and caret-drift refusal passed | The production controller appended Unicode once in a real multiline editor, and the independent fixture confirmed zero Apply clicks and no edit when the caret moved. Gesture logic passed automated tests; the installed bundle lacked AX access for an end-to-end physical gesture check. |
| Knowledge notes | Passed live | Created and edited a Unicode Markdown note and reopened it in the reader. File bytes and mode 0600 independently matched. Two selected fixture sources were indexed. |
| Scoped files and artifacts | Live read and refusal passed; artifact tests passed | The rebuilt app verified `read_file` for the selected fixture and returned its exact Arabic/emoji marker. A second request for a file outside scope was refused; the token was absent from saved history, and no grant was added. Automated checks covered overwrite, symlinks, byte readback, DOCX and XLSX. |
| Stop in the rebuilt app | Passed live | Started a harmless long response, used the visible Stop control, and checked both the workspace and isolated state later. No late response replaced the stopped status. |
| Briefings, scheduling and speech | Partial | The live app prepared two local suggestions from the two selected fixture sources. Native speech rendered non-silent PCM in memory. Scheduler unit tests covered app-running preparation; microphone capture and overnight wake were not exercised. |

The final Swift run registered 481 cases, with 475 executed and six opt-in desktop cases skipped during the automated run. The six real E2B inference cases and native speech render passed. The real Accessibility, agent-desktop, screen, focused draft, pointer and equivalent disposable Finder workflows were run separately in the authorized runner. The Python fixture/release checks passed 10/10 and the repository scenario suite passed 149/149; many of the latter are static or fixture checks.

The release app is built with an ad hoc signature; strict signature verification passed. That is a local development build, not a notarized distribution artifact. After QA, the same app reopened in the regular Relay profile and displayed its Workspace and Knowledge controls. This build still reports no macOS Accessibility grant, and no OS grants were changed during QA.

## Remaining parity gaps

Native Mail, Notes and messaging connectors; a model-generated incremental multi-source vault; wake from sleep for overnight preparation; cloud sharing and hosted provider options; broad screen/image reasoning; and signed distribution qualification. General browser or desktop automation still depends on the target's accessible controls, context grants and review rules. No real sends, submissions, transactions or credential flows were exercised.

> Latest source checkpoint (30 October): **309 tests / 51 suites passed in 2.282 seconds**, including strict raw-JSON spreadsheet number/separator validation. The current source adds explicit Mail-export reading, optional local semantic retrieval, private file persistence, canonical review binding and checked model-download resume. Four actual Gemma checks passed within a separate 14-test / 7-suite run (169.712 seconds); packaging and native QA are ongoing. No desktop action was dispatched by that run; this source-suite result does not certify the new packaged build, a native full-size model download, microphone operation, embedding quality or public release. Earlier packaged/live evidence below remains dated evidence.

## Latest release-gap checkpoint — 30 October 2026

Current source passed **354 tests in 56 suites** in 4.919 seconds (`/tmp/relay-release-final-tests.log`); optional native/hardware cases remain separate. Ten Python fixture/release tests passed. Five real Gemma GPU tests passed in 34.288 seconds with explicit float32 activations; two long literal-copy payloads matched UTF-8 exactly with 6000 bytes of additional context. The corresponding two CPU copies passed in 41.225 seconds; GPU copies took 13.597 seconds in this controlled invocation, not a universal performance guarantee. The same local two-step inference test passed in 1.852 seconds when launched inside a network-denial sandbox; a loopback connection negative control failed inside that profile and succeeded outside. No system network interface was disabled; this does not qualify all out-of-process macOS services or a physical airgap.

The native KV-state reuse experiment was removed after the actual SDK/model emitted empty tool IDs requiring application repair. Exact-projection safety guards refused retention. Each completion uses a fresh native session; the useful latency fix is removing two redundant informational completion turns. Lifecycle cancellation and monotonic inference budgets remain, with regression coverage.

Browser URL entry now uses target-bound writable AXValue plus advertised AXConfirm; queued URL keystrokes are removed. Safari hidden-tab identity absence fails closed with recovery. Live broad-browser qualification remains open after the preserved Chrome incident and external Chrome activity. Current package/native synthetic-speech verification is recorded in the end-of-file update below; public release still needs owner Developer ID credentials and actual hardened/notarized qualification.



# Native implementation status

**Current expansion: 30 October 2026.** Earlier sections below are chronological evidence, not the current complete feature list. See [current feature inventory and test plan](sentient-gap-roadmap.md) and [latest release evidence](release-evidence-2026-10-30.md). Browser/page reading, local knowledge, OCR, PDF/RTF, shortcut/selection drafts, writing preferences, read-only calendar foundations, manual suggestions and diagnostics have since been added. Each has separate verification limits.

29 October 2026. Relay is now a native SwiftUI executable app, not just an HTML specimen.

## Current source additions — 30 October 2026

The 309-test / 51-suite checkpoint supersedes earlier suite totals below. Current source includes the previous conversation/AX/browser, scoped knowledge/OCR, calendar, shortcuts, suggestions, speech-output and scoped file-move foundations, plus these increments:

- Explicitly selected `.eml` exports can be read and indexed locally. The bounded MIME reader extracts supported plain-text bodies, decodes supported transfer encodings/charsets, and omits HTML and attachments. Subject/sender/date headers are unverified source claims. No Mail account access, private database scan or sending is implemented. Exported Notes text/Markdown uses the existing selected-file path.
- Optional semantic retrieval starts off and requires explicit preparation of an available Apple Natural Language sentence embedding. Bounded in-memory ranking retains source provenance, freshness/scope checks and truthful lexical fallback/coverage. Deterministic injected-backend tests qualify lifecycle and ranking contracts; native embedding availability, retrieval quality and disconnected asset behavior remain unqualified.
- Native plain-text DOCX and PDF/RTF output, plus one-sheet values-only XLSX creation, are implemented. DOCX has native text reopen verification. XLSX stores strings literally, including formula-looking content; formulas, macros, external links and rich workbook editing are unsupported. The production XLSX path validates raw JSON before Double decoding: at most 1 MiB JSON, 128 bytes per numeric token, 15 significant coefficient digits (excluding leading/trailing mantissa zeros and exponent), magnitude at most 2^53−1, and no nonzero subnormal/underflowed numbers. Long IDs and exact decimals must be strings. Strict separators reject Darwin JSONDecoder's otherwise accepted trailing commas. Typed-number entry points cannot recover precision already lost by a caller.
- Document requests preflight output format and destination before writing. `write_file` refuses the four native formats PDF, RTF, DOCX and XLSX, directing them through their qualified native generators rather than writing plain text under a misleading extension. Artifact actions retain the actual destination and parent-folder path for inspection; a generated artifact is not evidence of live Office/Numbers rendering.
- Private local-file persistence stages mode-0600 files with empty ACLs before writing content, checks bounded byte readback and destination/staging identity, and reports uncertain post-commit outcomes. Caller-owned scope and overwrite review remain required. Canonical, structured review fingerprints bind reviewed values and recheck authority/state before effects.
- Model provisioning has checked 32 MiB chunk recovery with pinned manifest, strict range/strong-ETag handling, private FD/inode/prefix-hash checkpoints, serialized cancel/retry and full final SHA-256 before exclusive install. Recovery considers up to 64 active records and archives superseded metadata for the selected partial; unknown partials and invalid/retired backups are preserved, with no automatic garbage collection. Local-filesystem and unavailable-placeholder guards apply. Actual full-size CDN interruption/relaunch, disk exhaustion and native download UI qualification remain pending.

The separate real-model run passed 14 support/actual tests across 7 suites in 169.712 seconds, including four actual Gemma checks; it dispatched no desktop actions. The source-suite log is `/tmp/relay-final-current-tests.log`. A new packaged build and native QA are being checked separately. Synthetic transport, parser, filesystem and fake-embedding tests do not establish live app compatibility, semantic usefulness, a full offline microphone/audio matrix, GPU readiness, broad hardware coverage, signing/notarization or public-release readiness.

## Delivered

- Native conversation, persistent composer, runtime readiness, activity, Stop/resume/steering, artifacts, context grants, approved-memory edit/delete and local persistence.
- Embedded LiteRT-LM 0.18.1 with Gemma model import, CPU/GPU selection, engine loading and side-effect-free native tool-call readiness check. CPU is tested; GPU is not qualified here.
- Product-owned serial observe/model/tool loop, argument validation, budgets, bounded invalid-model-call repair, stale-state checks and no SDK automatic dispatch.
- Real app launch, scoped UTF-8/PDF reading, scoped text/Markdown/CSV writing with byte readback, AX observation/text entry/advertised scrolling, and exact qualified player controls.
- Approval of overwrites/website navigation binds state before review and rechecks before execution. Generic UI clicks and final sends/submissions remain manual in this alpha.
- Local-only inference; explicit user-requested browser navigation may use networking. No inference server, hosted model, API key, telemetry or shell tool.
- Build/packaging script, original icon, local ad-hoc signature, embedded dylib, third-party notices and pinned model download script.

## Model provisioned

Public LiteRT Community Gemma 4 E2B CPU-compatible `.litertlm` file:

- Repository: `litert-community/gemma-4-E2B-it-litert-lm`
- Revision: `1caa527c1e88b55f046fcd8d2b4265606680663d`
- Bytes: `2588147712`
- Verified SHA-256: `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`
- Local location: `~/Library/Application Support/Relay/Models/gemma-4-E2B-it.litertlm`
- Publisher metadata: ungated, Apache-2.0. Provenance JSON is alongside the downloaded model.

## Verified

- Release build and signed `.app` launch on the development Apple silicon Mac, 32 GB RAM.
- Regression suite passes (35 registered tests across 7 suites; real Gemma tests serialized, native fixture initialization also verified separately): native schemas and parsing, model budgets, no hidden reasoning output, executor Stop, bounded protocol repair, no whole-task certification from an observation, no crash replay, file/symlink scope, overwrite review drift, safe handlers, PDF extraction, AX policy and output budgets.
- Actual native LiteRT-LM initializes an official small test fixture.
- Actual Gemma loads on CPU, emits an exact harmless native tool call, consumes a tool result and answers without repeating it.
- Actual Gemma with all production schemas emits the exact requested file-write arguments in an integration test with no side effects.
- GUI model import/load/probe passes. GUI request “only open VLC” chooses the real launch tool, and NSWorkspace verifies the running VLC process before the app reports success.

- GUI file creation now executes through the model and serial executor, with independent byte readback and an artifact link. A first natural-language sample included ambiguous trailing instructions in the generated file. A follow-up with explicit quoted boundaries created `TestWorkspace/verification-exact.md`; an independent process verified that all 32 bytes exactly matched the requested string. Byte readback confirms the tool payload, not independent interpretation of every user intent.

## Computer-control direction

The user has suggested reusing an existing open-source interaction layer. Cua Driver is under source/documentation review as a replaceable adapter; it has not been installed or integrated into this build. Relay currently uses the native bounded AX implementation described above. Separate physical-Mac control requires an explicitly selected authenticated transport and is not implied by local app control.

## Remaining qualification

Form filling needs user-granted macOS Accessibility and a target exposing supported editable controls. That end-to-end scenario has not been executed on this Mac; its implementation and policy checks are not a universal compatibility claim. Screenshots/vision, coordinate fallback, OCR, arbitrary UI clicks, hosted inference, scheduled work, unrestricted shell, purchases and mobile are not implemented. Context extraction is bounded and explicitly reports omissions. Generic final actions are manual. Release percentages from the PRD remain unmeasured targets.

The Swift SDK carries upstream Sendable warnings in its Swift 5 module; Relay itself uses Swift 6 checking. Distribution is a local ad-hoc build, not Developer ID signed/notarized public release. A broader hardware/OS/app matrix and adversarial evaluation remain necessary.

## Accessibility test increment

Added bundled AppKit fixture, model-independent in-app AX check, opt-in real desktop tests, and a qualified visible Finder search action. Benign named buttons can now be reviewed with complete bounded window/input-context binding; excluded consequential controls remain manual. The local-model planning test maps “Open Finder and search for sf.webm” to exact `search_finder` arguments.

The updated app was rebuilt, signed and opened. Settings → Access → Run accessibility check was exercised: it correctly reports **Not run: enable Accessibility for Relay** on this Mac. No actual click/type/Finder end-to-end pass is claimed before that grant. The 28 focused permission-free regression cases pass; the full suite also passes with real Gemma planning, while desktop cases are explicitly skipped. See `accessibility-test-plan.md` for scenarios and invocation.

### Live macOS verification — October 29, 2026

Relay Accessibility access was refreshed for the current ad-hoc signed app with explicit user authorization and macOS authentication. All seven native fixture checks passed, including Unicode typing/readback, a real button press checked against an independent JSON oracle, stale/disabled rejection, changed-review rejection, and invalidated queued-click rejection. AXPress now uses a separate 500 ms action timeout rather than the short observation timeout.

The first Finder implementation populated AXValue without actually starting search; that earlier success evidence was insufficient. The revised workflow uses Finder's Find command, focused Accessibility element discovery, fixed PID-targeted query typing, and verifies the exact query plus the live Searching window title. Independent UI inspection observed `sf.webm` among five Finder search results after Relay typed the query. This proves that search ran; it does not establish exhaustive indexing or exact filename filtering.

Final Finder retest: from a normal Home window, the actual Relay chat request “Open Finder and search for sf.webm.” dispatched `search_finder` through local Gemma. Relay recorded verified exact query readback and `Searching “This Mac”`; independent CUA inspection showed five results including `sf.webm`. Final focused Accessibility contract suite: four tests passed. Release build and signature verification passed; current build's Accessibility switch is on.

### Discovery and action continuation — 29 October 2026

AssistantStore now persists the active objective, applies new steering constraints, and reiterates that objective on every model turn. When successful discovery-only work ends in a premature final response, up to two local completion checkpoints let the model continue an already authorized supported task. Checkpoints do not dispatch actions themselves. Failures, uncertain effects and mutations are excluded from automatic continuation. Informational answers and necessary clarifications remain permitted; this is bounded recovery, not a universal goal-completion proof.

Installed app resolution now checks exact display names, bundle names, filenames and identifiers with case/whitespace normalization. Ambiguous installed choices are rejected; display names appear in discovery results. The limited recorder alias remains a fallback after installed matches.

Eight new deterministic regressions cover app discovery and continuation, including Stop and uncertain mutation behavior. `swift test` passed with 55 registered tests across 13 suites (opt-in real-model/desktop tests skipped). Release build/signature verification passed. Live test through actual Relay chat, with Voice Memos initially closed: “open voice recorder” led local Gemma to dispatch `open_app`, verified process15730 / com.apple.VoiceMemos. Independent native UI inspection showed its All Recordings window; final response truthfully reported launch only. No recording began.

Second live natural-language check: “Find the installed calculator app and open it.” dispatched open_app and verified com.apple.calculator process15950; independent UI showed Calculator. This establishes another supported app launch, not general browser/form automation.

### Native first run experience — 30 October 2026

Added four-stage native onboarding: welcome/compatibility, local model provisioning, Mac permission/control checks, and a first-task draft. The visual identity uses an original coral/ice-blue Relay baton sculpture, restrained surfaces and large type inspired by the clarity and personality of the Sentient reference, without copying its orb or assets.

Native URLSession provisioning pins the recommended Gemma revision, byte count and SHA-256. It supports actual progress, cancel/retry, offline existing-file verification, import and non-overwriting install. Cancel restarts a transfer; resumable downloading is not implemented. A corrupt existing package is kept with a Finder recovery path. Model initialization can be canceled. Setup completion is distinct from model/permission readiness; resume and explicitly skipped/incomplete states stay truthful. Settings can reopen setup. No inference account or hosted fallback was added.

Validation: `swift test` passed with 65 registered tests across15 suites; opt-in desktop/real-model tests were skipped in that invocation. Ten new tests cover compatibility/persistence plus downloader hash/size/HTTP/success/error/cancellation paths, including actual URLSession transport against a tiny URLProtocol fixture. No fresh2.59GB remote transfer was performed.

Live native walkthrough: detected existing recommended model; verified its full checksum offline; loaded embedded Gemma and passed native tool-call probe. Refreshed the same already-authorized Relay Accessibility grant after rebuild. All seven native fixture checks passed through onboarding. A relaunch correctly exposed the unloaded model and Return to model setup. First-task handoff populated “Open Calculator” without dispatch. Settings reopening returned to Welcome. Final release build/signature validation passed. Native welcome screenshot saved as planning/onboarding-welcome.png.

Still unqualified: fresh full-size remote download under slow/interrupted networks; visual layout at minimumwindow with every error expanded; VoiceOver walkthrough; cancellation of a slow real runtime initialization (the probe completed before the attempted UI cancel). Release signing/notarization remains required to avoid ad-hoc build grant changes.


Latest package built successfully with ad-hoc signing, relaunched, loaded local Gemma and passed its probe. Native fixture7/7 passed. One synthetic .eml read returned exact accented body, qualified sender, omitted HTML/remote content; original sixfixture hashes unchanged. Artifact grid/folder/fullpathAX and semantic-off UI inspected. See final fourth-package section in release evidence. Native semantic preparation/microphone/audio and public distribution remain unqualified. Informational-request completion-checkpoint latency/awkward reply is an open UX defect.


## Integrated package and outstanding handoff

The final integrated source passed **362 tests in 56 suites** in5.262seconds (`/tmp/relay-release-integrated-tests.log`). Ten Python tests passed3.119seconds. The development app packaged and passed strict signature verification (`/tmp/relay-release-integrated-build.log`); main executable SHA256 `e0d75a1965a764d86e6d659600c412d0c0cd5451e20e0d0acc132fbad646c301`. This Mac's saved configuration uses GPU with explicit float32 activations and the actual app passed its local engine/tool-call readiness probe. CPU remains the general default for other installs/configurations.

Model preparation now has one owner, protects against repeated Load/late Stop/configuration changes, preserves drafts and disables conflicting controls. Four suspended-load/probe regressions cover those boundaries. Safari's reader now distinguishes its non-tab content group while still traversing that group for the document; actual tab ambiguity, security and URL checks remain strict. The latest natural-language Safari task before that reader repair failed safely without navigation; the subsequent live browser matrix is still open. The final loopback fixture state is saved, and development servers were stopped.

The no-microphone speech diagnostic refused before generating audio because app-process Speech authorization was unavailable, even while macOS showed Relay's existing entry On. Only that existing Speech entry was refreshed and the app fully relaunched; no microphone capture occurred. A separate explicit Recheck Speech access action now checks through the native API and does not automatically start a diagnostic or dictation. The integrated app is currently awaiting that macOS decision. Computer-use safety checks blocked access to `com.apple.UserNotificationCenter`; the human must handle any system consent dialog directly. No protected UI was bypassed, no TCC database or security protection was modified, and no synthetic ASR success is claimed while authorization is pending. Read aloud is off; capture is off; no transcript was sent or saved by these diagnostic checks.

Public release remains blocked: local signing preflight reports zero Developer ID Application identities and no configured notary profile. The signed/notarized path is implemented and tested at its local gates; no Apple upload occurred. A failed ad-hoc hardened candidate was preserved with a non-runnable `.hardened-launch-failed` suffix to avoid advertising a duplicate app. Real certificate-backed hardened launch, notarization, clean-browser operations, physical recognition accuracy/device routes, physical shortcut delivery and a broader offline matrix remain open. The complete preflight is `planning/distribution-preflight.json`; signing instructions are in `planning/distribution-readiness.md`.

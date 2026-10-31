# Relay release-gap progress

30 October 2026. This checkpoint addresses the four gaps called out after the previous alpha: conversation latency, application compatibility, voice qualification, and signed distribution. It does not declare a production release or full Sentient feature parity. Earlier evidence is preserved in [release evidence](release-evidence-2026-10-30.md); the broader backlog remains in [the gap roadmap](sentient-gap-roadmap.md).

## Current verified checkpoint

| Check | Result | What it proves / limits |
| --- | --- | --- |
| Integrated Swift suite | **325 registered tests / 53 suites passed in 2.537 seconds** after compilation; `/tmp/relay-release-gaps-final-tests.log` | Includes the new conversation and speech qualification regressions. Registered totals include separately gated integrations; this is not 325 live desktop tasks or a task-completion rate. |
| Final development package | Built successfully; `/tmp/relay-release-gaps-final-build.log` | `build/Relay.app` remains the ordinary ad-hoc development build. Strict signature verification is distinct from Developer ID signing, notarization, and hardened-runtime launch. |
| Release/qualification Python suite | **8 tests passed in 2.037 seconds**; `/tmp/relay-release-python-final.log` | Four browser-fixture tests and four release-gate tests, detailed below. Synthetic server behavior and pipeline failure handling do not prove real browser adapters or Apple acceptance. |
| Native synthetic speech rendering | **1 explicitly enabled test passed in 0.568 seconds**; `/tmp/relay-native-speech-render.log` | Installed nonpersonal Apple voice `com.apple.eloquence.en-GB.Eddy` produced **46,593 finite, bounded PCM frames**, included non-silent samples, and reached its terminal callback. No speaker playback, microphone capture, personal voice, downloaded voice, or disconnected operation was exercised. |
| Packaged local-model replay | The selected synthetic mail export returned its exact accented body and a short unverified-sender note | Native Activity contained `read_file` and `Response finished`, without an added follow-through check in this run. [Saved native AX evidence](native-latency-replay.txt) includes older visible history as well as the new response; the old “second checkpoint” response is historical, not the replay result. |

Timing above is the duration of each test invocation. It is not a device-wide inference benchmark, a latency percentile, or an offline/network audit.

## Conversation latency and response quality

The previous executor discarded every final answer after a discovery-only run and asked the model to reconsider it twice. Reading a file successfully therefore incurred two unnecessary model completions and sometimes surfaced “second checkpoint” wording.

The executor now finishes ordinary informational responses directly. It permits **one** reconsideration only when the current reply explicitly proposes handing another step back to the user. This recovery hint examines model phrasing; it never decides that an action is authorized, never constructs a tool call, and never bypasses scope, review, current observations, cancellation, or secure-field restrictions. Recognized English handoff phrasing is deliberately narrow. Unrecognized phrasing finishes normally rather than guessing an action. Quoted lines and fenced code are excluded from this hint.

The numbered checkpoint reminder has been replaced with a request to reconsider an already-proposed handoff. System guidance asks the model to return requested information directly and keep internal reminders out of the answer. Prompt guidance reduces this behavior; it is not an absolute guarantee that every generated response will be concise.

| Regression / native check | Expected behavior and evidence |
| --- | --- |
| Installed-app informational question | Exactly two scripted model turns: one discovery call and one final answer; no follow-through check. |
| File, calendar, knowledge, browser-page, and scoped-file-search information | Five parameterized scripted cases finish in two turns, with one verified read dispatch and no discarded final answers. |
| Authorized Voice Memos opening after premature handoff | One reconsideration lets the model request the advertised `open_app`; ordinary executor and evidence rules still apply. |
| Repeated handoff | Finishes after a bounded three scripted turns; it does not loop, invent a launch, or mark the objective independently completed. |
| Stop during reconsideration | A subsequently returned action is not dispatched. |
| Uncertain mutation | Not retried by this recovery path; remains uncertain and needs inspection. |
| Quoted/fenced handoff text | Four source-quotation/code cases produce no extra planning call. This is bounded phrase-handling coverage, not a general prompt-injection guarantee. |
| Ambiguous target | Recovery instruction still permits one necessary question; no app is launched by the hint itself. |
| Actual installed Gemma, packaged mail replay | New response directly returned `The synthetic launch review is Tuesday at 10. Café.` and qualified `fixture@example.invalid` as unverified. The observed run had one `read_file` outcome and no `Checking next step` event. It did not browse or change files. |

Remaining latency work: controlled warm/cold measurements, first-response and total-task timing, memory/thermal/resource contention, longer conversations, interruption under load, multilingual handoff behavior, and held-out requests. Two versus four scripted completions is a verified call-count reduction; no universal speedup factor is claimed.

## Broader app and browser compatibility

A synthetic localhost browser fixture and independent state oracle now cover ordinary Unicode reading, an explicit form, redirects, and secure-field refusal cases. Python tests verify:

1. Only the exact synthetic form changes the independent state.
2. Read-only content includes Unicode, has no external assets, and produces no form effect.
3. Redirect and secure-control routes are explicit controlled cases.
4. Wrong Host, unknown route, and oversized body requests do not mutate state.

These are fixture/server tests. Current-package Chrome and Safari adapter checks are being carried out separately by the parent task and will be appended when their exact results are available. No success is inferred here from the fixture passing.

The existing native accessibility fixture checks remain useful but qualify a controlled application rather than arbitrary apps. Live qualification should report each browser/app/version, selected document or window, requested action, independent result oracle, failure/uncertainty, and whether a model or a direct adapter initiated the action.

Remaining compatibility gates:

- Chrome and Safari navigation/read/search, redirects, authentication, selected-tab/window drift, loading failures and permissions.
- Synthetic form text entry, exact fresh review, changed-field rejection, disabled controls, secure-field refusal, and no unintended submission.
- Finder search with exact punctuation/Unicode, multiple windows, absent results, and stale observations.
- Installed app aliases, ambiguous targets, launch failures, and app-version differences.
- Qualified media playback controls and independent playback evidence; launching a player alone does not count.
- Stop, source revocation, app closure and UI changes during pending actions.
- Held-out real task completion by category with a documented denominator. No aggregate reliability target is marked achieved.

## Voice qualification

Speech output now explicitly qualifies an installed voice through identifier lookup and excludes third-party/personal voices. No voice catalog or playback starts at controller initialization; playback remains explicit and off by default. Automated controller and Store tests cover bounded text, selected voice, cancellation, stale callbacks and teardown.

The separate native render test uses `AVSpeechSynthesizer.write` on a short synthetic utterance. It inspects bounded scalar PCM observations under a lock; it does not invoke `speak`, store PCM, use a microphone, or request consent. Eddy rendered non-silent buffers and completed. This closes the narrower native-generation uncertainty for that installed English voice on this Mac.

Still unqualified:

- Actual speaker audibility, output-device changes, Bluetooth/headphone routing, interruption, volume and speaker Stop latency.
- Live microphone/Speech consent, on-device recognition, unsupported locale/device paths, silence/noise, permission revocation and partial/final transcript behavior.
- Air-gap behavior of actual output and recognition, cold caches, language assets and model/runtime startup.
- Other installed voices/languages, all supported macOS versions, accessibility behavior, and long-response playback.

No microphone or Speech permission was requested or granted by this render test. No live recording or audio playback is claimed. Further live capture tests require the specific consent boundary to be satisfied separately.

## Signed distribution

`Scripts/release-app.py` implements explicit stages:

- Local prerequisite check; no build, signing, upload or credential creation.
- Preparation of a unique candidate copy, leaving the running build and prior candidates intact.
- Explicit exact Developer ID Application identity selection; development, ad-hoc and unrelated identities cannot be silently substituted for public distribution.
- Nested Mach-O code and bundles signed inside out with hardened runtime, strict verification, reviewed minimal entitlements and arm64 checks.
- Explicit notarization mode using an existing notarytool credential profile; require Apple's `Accepted` response before stapling, validation, Gatekeeper assessment, final archive and SHA-256.

Release-gate tests cover exact identity/private-key selection, refusal of packaged private data and escaping symlinks, inner-before-outer signing order, and missing notarization credentials causing no signing/upload.

### Concrete blockers found on this Mac

1. **No available Developer ID Application identity with private key** was found. Public distribution cannot be signed with the available development identities or an invented identity.
2. **No notarization credential profile is configured** for this release. The pipeline does not create, read out or guess credentials.
3. A separate **ad-hoc hardened-runtime candidate passed code-signature verification but failed to launch before UI**, reporting a DYLD missing-library failure. The ordinary development package continues to launch; signing verification did not prove hardened-runtime engine compatibility. Runtime dependency diagnosis and successful hardened cold launch/model/tool probe are required before distribution.

`/tmp/relay-hardened-check.log` records candidate construction/signature verification, not successful launch. No notarization submission, Apple acceptance, stapled public release, or Gatekeeper approval is claimed.

Remaining distribution gates: diagnose the hardened runtime dependency failure; test candidate engine/model initialization and synthetic tools; provision the owner's correct distribution identity/profile; notarize and staple; assess a clean downloaded copy; verify quarantine, first-run permissions, stable TCC identity, update/rollback and uninstall behavior. No release credentials are requested in this document, and no external upload is implicit in local preflight.

## Release decision

The ordinary local development build is packaged and its narrow native mail replay is verified. The four release gaps have concrete implementation and test progress, but **public release remains blocked** by hardened launch plus signing/notarization prerequisites. Broader browser/app, physical voice/device and offline qualification remain separate incomplete gates. This checkpoint must not be presented as complete feature parity or a product-wide reliability result.


## Later native gates and repairs

The initial Safari navigation refused before address entry because a single hidden tab exposed no selected-tab identity. A proposed automatic bootstrap was rejected in critique: newly exposed AX objects did not prove a newly created logical tab. That helper was removed. Safari keeps manual visible-tab/second-blank-tab recovery and ignores only fully inspected zero-direct-tab content groups. An actual visible-tab Safari navigation/read pass is still required.

The Chrome fixture request failed selected-tab verification; later native inspection found the synthetic `/submit/` route and its rejection text. Native AX did not expose HTTP status. Fixturev1 counted only accepted submissions, so accepted0 did not prove attempted0. The incident is preserved in `planning/chrome-incident-2026-10-30.txt` and `planning/chrome-incident-activity.png`; cause remains unknown. Chrome subsequently reported external/user activity twice through the UI tool, so repeated control attempts stopped. No personal tab was closed. Browser navigation now rechecks exact address focus immediately before a target-bound advertised AXConfirm action; no Return fallback remains. This is a safety change requiring new native qualification, not proof that the incident is solved.

Fixturev2 adds every POST attempt/rejection and a bounded redacted route history plus a form-free diagnostic route. Ten Python tests passed3.089seconds. The source suite after removal of unsafe bootstrap passed331tests/54suites in2.556seconds. The development app packaged and launched with local Gemma/probe ready. Those counts are supporting automated checks, not a live task-completion percentage.

Native speech output in the packaged app used explicit Eddy/en-GB selection and only the synthetic phrase generated by local Gemma. UI entered Reading/Stop audio state and returned inactive after the short response. Stop was attempted after the control had already disappeared, so that attempt does not qualify interruption. Physical audibility, route changes and airgap behavior remain separate; no microphone was active during that output check.

After explicit user approval for one bounded microphone check, first native start crashed while Speech authorization callback inherited MainActor on a background TCC queue. Root-cause stack named AppleOnDeviceVoiceBackend.requestPermissions and Swift executor assertion. A nonisolated authorization bridge and explicit Sendable boundaries for authorization/audio tap/recognition/configuration callbacks fixed this source defect. A real background-queue regression was added;332tests/54suites passed2.623seconds and the app rebuilt. Retry reached Listening in EnglishUS without the crash; Escape stopped/discarded and draft stayed empty. No raw transcript/audio was written by this test or sent as chat. Exact capture duration and recognition accuracy were not verified after the asynchronous consent wait; this is not a passed10-second test. A user-visible app-controlled duration limit is being added before any further recording. No second capture will run without renewed explicit approval.

The hardened-candidate script now labels construction STATIC SIGNATURE VERIFIED; RUNTIME NOT TESTED rather than implying a launch test, and blocks actual Relay state filenames, .litertlm files and checkpoint/private-staging names from app artifacts. The ad-hoc hardened launch failure and missing DeveloperID/notary credentials remain public-release blockers.


## App-controlled duration checkpoint

The recording-limit UI and monotonic deadline changes passed336tests/54suites in5.020seconds (`/tmp/relay-voice-duration-tests.log`) and packaged successfully (`/tmp/relay-voice-duration-build.log`). The native screen showed EnglishUS, Recording limit10seconds, Maximum10seconds and capture off before renewed explicit approval. Screenshot: `planning/native-voice-10-second-ready.png`.

The approved fresh check initially showed permission/preparation wait. At the next observation12.830seconds after Start it was still recording. The bounded UI extraction returned no transcript text, but did not preserve whether the expected AX region matched; recognition is therefore unverified, not proven absent. Escape then closed/discarded and the chat draft remained empty. Since the native capture-start instant was not externally observed, that wall interval does not establish that the10-second recording deadline was exceeded; it also does not qualify native automatic stop or recognition accuracy. No further microphone capture is authorized by that consumed one-test approval. Root retained only boolean/character-count results, not raw transcript or audio. No transcript was submitted to chat.

A read-only hardware metadata query reported default input MacBookProMicrophone, one input channel,44100Hz. No input/output device setting was changed and this query did not record audio. It does not explain the absent transcript or prove hardware audibility. Voice qualification remains partial; the native callback crash is repaired and the app reached recording, while controlled recognition, automatic deadline, route changes and true offline checks remain open.

## Final source and inference checks

354 tests / 56 suites passed4.919seconds,10 Python fixture/release tests green. Native KV reuse was removed after the real initialretention decision was repairedID; no guard was weakened. The reduction from four model turns to two and native sessions remaining fresh are separate facts.

GPU uses explicitfloat32 activation configuration; CPU remains the general app default. All 5 real Gemma tests passed in 34.288 seconds: nativecall/result, fullschema exactwrite, two long literal-copy payloads, exactFinderquery planning, productionprompt/fakeexecutor loop. None dispatched realdesktopactions. CPU longcopies passed in 41.225 seconds (23.224/17.999 per case); GPU took 13.597 seconds (7.793/5.689), both cases byte-exact. This one controlled comparison is not a benchmark acrosshardware/models or proof of allcopycases. CurrentSDKknownprecision rationale: https://github.com/google-ai-edge/LiteRT-LM/issues/3913 .

The network-denial launch initially failed because SwiftPM tried applying a nested sandbox. The corrected invocation retained the outer `(deny network*)` profile and disabled only SwiftPM’s nested manifest sandbox. The filtered realGemmatwo-step test then passed in 1.852 seconds with two fresh conversations. A loopback server was reachable outside that profile and curl could notconnect inside; no system-wide networking was changed. Scope is this localtest process harness, not allOSservices/physicalairgap. Logs: `/tmp/relay-offline-inference.log`, `/tmp/relay-network-control-denied.log`.


## Integrated package and outstanding handoff

The final integrated source passed **362 tests in 56 suites** in5.262seconds (`/tmp/relay-release-integrated-tests.log`). Ten Python tests passed3.119seconds. The development app packaged and passed strict signature verification (`/tmp/relay-release-integrated-build.log`); main executable SHA256 `e0d75a1965a764d86e6d659600c412d0c0cd5451e20e0d0acc132fbad646c301`. This Mac's saved configuration uses GPU with explicit float32 activations and the actual app passed its local engine/tool-call readiness probe. CPU remains the general default for other installs/configurations.

Model preparation now has one owner, protects against repeated Load/late Stop/configuration changes, preserves drafts and disables conflicting controls. Four suspended-load/probe regressions cover those boundaries. Safari's reader now distinguishes its non-tab content group while still traversing that group for the document; actual tab ambiguity, security and URL checks remain strict. The latest natural-language Safari task before that reader repair failed safely without navigation; the subsequent live browser matrix is still open. The final loopback fixture state is saved, and development servers were stopped.

The no-microphone speech diagnostic refused before generating audio because app-process Speech authorization was unavailable, even while macOS showed Relay's existing entry On. Only that existing Speech entry was refreshed and the app fully relaunched; no microphone capture occurred. A separate explicit Recheck Speech access action now checks through the native API and does not automatically start a diagnostic or dictation. The integrated app is currently awaiting that macOS decision. Computer-use safety checks blocked access to `com.apple.UserNotificationCenter`; the human must handle any system consent dialog directly. No protected UI was bypassed, no TCC database or security protection was modified, and no synthetic ASR success is claimed while authorization is pending. Read aloud is off; capture is off; no transcript was sent or saved by these diagnostic checks.

Public release remains blocked: local signing preflight reports zero Developer ID Application identities and no configured notary profile. The signed/notarized path is implemented and tested at its local gates; no Apple upload occurred. A failed ad-hoc hardened candidate was preserved with a non-runnable `.hardened-launch-failed` suffix to avoid advertising a duplicate app. Real certificate-backed hardened launch, notarization, clean-browser operations, physical recognition accuracy/device routes, physical shortcut delivery and a broader offline matrix remain open. The complete preflight is `planning/distribution-preflight.json`; signing instructions are in `planning/distribution-readiness.md`.


## Speech approval follow-up — synthetic recognition passed

After the user confirmed allowing Relay Speech access, the actual app’s separate “Check local speech support” completed successfully: “on-device recognition matched the generated phrase,” 37,159 generated audio frames, 0.8 seconds. This used the microphone-free in-memory diagnostic, with no speaker playback, audio file, chat submission or hosted recognition fallback. This qualifies one synthetic phrase only; physical microphone accuracy, the native ten-second capture deadline and physical offline operation remain unqualified. The earlier Speech authorization blocker is resolved for this diagnostic.

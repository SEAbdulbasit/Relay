# Voice release qualification

30 October 2026. Voice is optional and off by default. This document separates software regressions from hardware evidence. A fake backend cannot prove microphone capture, recognition accuracy, audio routing or disconnected operation. No physical recording, permission grant or speaker playback was performed by this review.

## Implemented boundary

- Input: explicit Start → supported locale and on-device capability → macOS microphone and Speech consent → the selected10/30/60-second recording limit (default30) for in-memory capture → separate reviewable transcript → explicit Add to draft → explicit Send. No automatic submission or audio file is created. Unsupported on-device recognition refuses capture; there is no hosted fallback.
- Output: explicit enable, explicit installed nonpersonal Apple voice, explicit existing assistant response. Responses over8KB are refused rather than truncated. No automatic voice selection, voice download, auto-read on response, SSML execution or hosted speech fallback.
- Stop, cancel, source invalidation, new request and lifecycle paths stop owned speech resources. Cancellation does not dismiss an OS-owned permission dialog; late consent cannot start canceled capture. A partial transcript can remain for review after Stop/error; Cancel clears it.

## Software regressions

Existing tests cover silent initialization; malformed/unsupported locales; unavailable local recognition; denied permissions; capture failure; exact Unicode transcript; explicit draft append without autosend; transcript byte/duration bounds; interruption; late callbacks; Stop during permission prompt; explicit voice qualification; stale output delegates; source invalidation and task integration.

This batch adds six focused cases:

| Case | Required result |
| --- | --- |
| Two Start requests while permission is pending | One capability check, one permission request and one capture |
| Calling task canceled while permission is pending | Late grant cannot start capture; controller settles stopped |
| Final callback synchronously during backend start | Final transcript stays stopped; subsequent failure is ignored |
| Embedded NUL/control character in recognition text | Stop capture, retain last ordinary transcript, report error; no draft mutation |
| Audio backend starts then throws | Stop owned backend, clear active state, ignore failed-run callbacks, permit explicit retry |
| Selected output voice disappears | Stop playback, clear selection, require explicit new choice; no fallback |

These tests use injected backends and are awaiting the parent-coordinated build/test run. They neither prompt nor activate audio devices. Native recognition still sets `requiresOnDeviceRecognition = true`; native audio taps append only to the in-memory recognition request, with serialized teardown.

## Native device matrix — pending human-authorized execution

Use the packaged app, a disposable draft, a synthetic sentence and no personal content. Record macOS version, hardware, selected locale/voice, route and network state. Do not put raw audio or private transcripts in diagnostics.

| Gate | Procedure | Pass / edge case |
| --- | --- | --- |
| First-run consent | Start dictation and choose Deny separately for microphone and Speech on a fresh test profile | Actionable denial, no active recording or fallback. A later explicit Start can recover after consent is changed in macOS |
| Consent cancellation | Start with consent pending, cancel/close voice sheet, then complete pending OS prompt | No capture begins and draft stays unchanged |
| Successful on-device capture | Explicitly authorize microphone/Speech and dictate “Relay local check. Café. One two three.” | Review text shown, capture indicator ends on Stop, no message sent; explicit Add preserves existing draft |
| Accuracy | Use fixed sentences per supported language,10trials each, including punctuation, names and numbers | Report word error rate with denominator, substitutions and unrecognized trials. Do not declare a universal accuracy score |
| Disconnected input | Provision required OS language assets first, disconnect network, repeat capture | Transcription works locally or explicitly reports unavailable; no hosted fallback. Record external process/network observations separately; a code flag alone is not an airgap proof |
| Locale unavailable | Select an unsupported/unprovisioned language, including after relaunch | Refuse before capture; allow language change; no silent English or server fallback |
| Duration and silence | Stay silent; then dictate beyond30seconds | Capture stops by deadline, no silent submit/restart, reviewable partial text, UI remains responsive |
| User Stop and close | Stop during partial recognition; close sheet; start a new capture | Tap/task torn down, later callbacks cannot overwrite the new session |
| Input route loss | Unplug selected USB microphone or disconnect Bluetooth during capture | Interrupt or actionable failure, no hidden continuing capture; restart only explicitly |
| Sleep / wake | Sleep during recording and wake | Input stopped, partial text retained for review, no automatic restart |
| Consent revoked mid-capture | Revoke input/Speech access through macOS | Capture ends/errors; no restart until explicit user action |
| Local output | Select installed nonpersonal Apple voice; read one synthetic assistant response | Correct response and voice audible; start/finish state matches playback; other answers remain silent |
| Output Stop | Stop while preparing and while speaking; start another response | Old audio and stale callbacks cannot revive or interrupt new output |
| Audio route change | Switch speakers/headphones/Bluetooth while speaking | No crash or indefinite active state; Stop works. Record whether playback follows macOS route or ends |
| Output offline | Disconnect network and speak with provisioned voice | Playback succeeds locally or reports unavailable, without downloading or voice substitution |
| Output disappearance | Remove selected downloaded voice outside Relay, refresh voices | Clear selection and stop active playback; require another explicit voice |
| Output sleep / quit | Sleep, close app window or quit while speaking | Speech stops; relaunch begins disabled and silent |
| Accessibility | Keyboard-only navigation and VoiceOver through input review/output controls | Names, focus order, recording status, Stop and errors understandable without relying on color |

macOS permission changes and actual microphone capture require direct action-time authorization or the user's own interaction. The parent agent owns that handoff. Speaker output still needs a real listening oracle; starting the synthesizer or receiving a delegate callback does not prove the selected route was audible.

## Release acceptance

Release voice only with the software suite green and a recorded native minimum matrix: consent refusal/recovery, successful capture, offline capture, cancel/Stop, route loss, sleep, explicit output, output Stop and offline output. Unsupported languages/routes stay described as unavailable rather than marked qualified. No native gate in this document is currently marked passed.

## Opt-in native buffer gate

`NativeSpeechRenderTests.installedAppleVoiceRendersBoundedNonSilentPCMWithoutPlayback` calls Apple's [`write(_:toBufferCallback:)`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write%28_%3Atobuffercallback%3A%29) with the fixed synthetic phrase “Relay local check. One two three.” It inspects finite/nonzero PCM and a terminal buffer, retaining only scalar counts. It never invokes `speak`, accesses a microphone, saves audio or asks for Speech/microphone permission.

Run only when explicit native rendering qualification is intended:

```sh
RELAY_RUN_NATIVE_SPEECH_RENDER_TEST=1 swift test --filter NativeSpeechRenderTests
```

By default the harness chooses one installed, nonpersonal English Apple voice in identifier order and logs that identifier. Set `RELAY_NATIVE_SPEECH_VOICE` to qualify one particular installed English voice; missing/unavailable choices fail, with no fallback or download. This test is skipped in the normal suite. Parent execution is pending. A pass qualifies that voice's synthetic buffer production on that machine, not physical playback, input recognition, locale coverage or offline behavior.

## Follow-up sleep teardown repair

The native dictation backend previously forwarded `willSleep` through a newly queued main-actor Task. That teardown could be delayed until wake. Sleep handling now belongs to the input controller with a main-queue notification observer and synchronous main-actor Stop, including a pending permission request. Backend audio resources are stopped before observer delivery returns, and late consent cannot start the old session. Two new tests use an isolated notification center: immediate teardown without yielding, stale result refusal, and pending-consent invalidation. Actual hardware sleep/wake still needs the native matrix.

Parent-reported opt-in native PCM run passed using installed Apple voice Eddy with46,593frames. This is synthetic buffer evidence only; no audible playback, microphone or offline claim. Full coordinated test/build results remain owned by the parent.

## Native authorization failure and limited retry evidence

The user authorized one10-second input test. Its first native Start crashed before capture in the Speech authorization callback: a legacy callback inherited MainActor isolation but TCC delivered it on a background queue. The repair introduced a nonisolated, explicitly Sendable raw-status continuation bridge and explicit Sendable boundaries for recognition results, audio taps and configuration callbacks. A real background-queue regression exercises the production authorization bridge. Parent reported332tests/54suites passed in2.623seconds and a successful package (`/tmp/relay-voice-native-fix-build.log`).

The retry survived and reached Listening in English(US). Escape then closed/discarded the transcript and left an empty draft, without raw audio files or chat submission. Consent wait made the externally timed interval unreliable: the selected capture limit was still30seconds and the actual capture-start instant was unknown. This does **not** qualify a10-second recording limit, recognition accuracy, consent-to-capture timing or offline recognition. The approved test is consumed; no additional recording is authorized without another explicit action-time approval.

Native output evidence is also limited: Eddy started through the app backend and showed its active reading state. The short phrase completed before the attempted Stop click, making that click stale. This qualifies startup/normal completion only, not actual mid-utterance Stop. Fake-backend tests remain the Stop evidence. Native PCM rendering is a separate direct-framework buffer test and does not qualify the app backend lifecycle.

## Session recording limit — source changes awaiting verification

The input sheet now offers10/30/60-second recording limits, default30, for this app session only. The control is disabled during consent wait/capture. The controller rejects nonfinite/out-of-range changes and refuses changing a busy session. A ContinuousClock instant is taken immediately before native begin, after consent, and the stop task sleeps until that fixed deadline. Native startup cannot add another full recording interval. A session-only numeric elapsed upper bound includes startup and teardown, with no persisted transcript, audio or raw timestamp; this is a QA observation, not proof of acoustic capture duration.

Added software cases cover default/session-only bounds, busy-change refusal, exclusion of consent wait from the deadline and elapsed metric, and a slow synchronous native start exhausting its budget before return. These time-sensitive cases are serialized within the input suite. Real hardware duration remains pending a newly authorized test with the selected10-second app-controlled limit.

## In-app synthetic recognition diagnostic — pending coordinated verification

Settings → Voice now has “Check local speech support.” It lazily creates an on-device English(US) recognizer, requires already-authorized Speech access, and feeds only the fixed generated phrase “Local voice check one two three” from an explicitly assigned installed nonpersonal English Apple voice. Existing PCM buffers are supported by Apple's [buffer recognition request](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest). Both `supportsOnDeviceRecognition` and [`requiresOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition) are required. Missing authorization/support/assets fail with fixed messages; no permission request, hosted fallback or voice download is made.

The check uses `AVSpeechSynthesizer.write`, not speaker playback or AVAudioEngine input. PCM is appended immediately under a lock, bounded to4million frames and a20-second controller deadline; endAudio is one-use and no append follows teardown. No audio file or chat message is produced. Final recognition text is compared transiently and discarded; observable results contain only pass/failure, fixed status, elapsed seconds and frame count. Matching ignores case/punctuation and equates the final number sequence “one two three,” “1 2 3” and “123”; extra words/missing audio/malformed or oversized results cannot pass.

Injected-backend tests cover silent initialization/permission failure, final-only expected match with frames, mismatch/raw-text exclusion, duplicate Start, Stop→retry/stale callbacks, malformed text/frame limits, timeout, synchronous completion/partial-start error and synchronous sleep teardown. Global Stop, new request/unload and voice-sheet lifecycle hooks are coordinated by the parent. Native rendering→recognition result and the packaged UI remain pending; a pass would qualify one synthetic phrase with installed assets, not microphone transcription, acoustic accuracy, audible playback or offline operation.

## Synthetic diagnostic permission-state investigation

The packaged synthetic check returned a permission failure with0frames even while Relay’s existing Speech setting appeared enabled. Refreshing that entry and relaunching did not establish a working synthetic recognition result. Apple's [`authorizationStatus()` documentation](https://developer.apple.com/documentation/speech/sfspeechrecognizer/authorizationstatus%28%29) describes a current-process authorization query and does not state that recognizer initialization is required; it also notes denial can reflect unsupported speech recognition. The mismatch remains unresolved rather than proving that TCC allowed this process.

The diagnostic now initializes its English recognizer client before querying status, aligning the client order with dictation, and reports the exact typed state: not determined, denied, restricted or unknown. No authorization request, microphone call or recognition task is made unless the query is authorized. This is a narrow initialization hypothesis and diagnostic improvement, not a proven consent repair. A regression checks state mapping and fixed failure labels with0frames, without using OS consent APIs. Current ad-hoc process identity and device authorization behavior still need native investigation.

## Separate explicit Speech-access recheck

Settings → Voice now separates “Recheck Speech access” from the synthetic check. Only this explicit button invokes Apple's `requestAuthorization` through the nonisolated Sendable callback bridge. It may display a macOS Speech prompt, never requests microphone access, and never starts dictation, synthesis or recognition automatically. Successful permission handling returns to idle; the user must explicitly run the local synthetic check afterwards.

The controller marks this phase authorizing/busy. Stop, closing the page, sleep or other owner invalidation cancels the local operation and invalidates late results. The OS may keep its consent dialog open; later completion cannot start a check or overwrite the stopped state. Injected authorization tests cover authorized, denied and canceled-then-late-approved outcomes, with no real permission prompt. Existing microphone and synthetic checks keep their separate boundaries. This SDK recheck may help reconcile current-process status but is not a proven repair for the prior enabled-settings mismatch. Parent owns native execution and final verification.


## Fresh approved 10-second attempt — permission blocked

The latest approved attempt selected the visible 10-second limit before Start. Relay remained at “Checking on-device speech and permissions…” through the observation interval and never visibly reached Listening. The permission wait was canceled; Relay reported “Voice input stopped. No transcript was captured.” Closing discarded the session; the main draft was empty and Send disabled. No recognition or automatic-duration pass is claimed. The outstanding macOS Speech consent decision must be handled by the user; prior computer-use access to the protected consent app was blocked and was not bypassed.


## Speech approval follow-up — synthetic recognition passed

After the user confirmed allowing Relay Speech access, the actual app’s separate “Check local speech support” completed successfully: “on-device recognition matched the generated phrase,” 37,159 generated audio frames, 0.8 seconds. This used the microphone-free in-memory diagnostic, with no speaker playback, audio file, chat submission or hosted recognition fallback. This qualifies one synthetic phrase only; physical microphone accuracy, the native ten-second capture deadline and physical offline operation remain unqualified. The earlier Speech authorization blocker is resolved for this diagnostic.

# Relay macOS compatibility qualification

30 October 2026. Capability evidence is scoped to an exact operation, application build, OS version and fixture. A passing local-model probe or synthetic AX test does not qualify every application. This document does not upgrade earlier observations into current-build evidence.

## Current support and limits

| Surface | Implemented adapter | Existing evidence | Open release gate |
|---|---|---|---|
| Synthetic native app | Separate-process observe, reviewed AX value entry, button press, independent JSON effect | Prior final package passed seven fixture checks | Re-run after any adapter/build/signature change; missing/revoked permission, disabled control, stale observations, changed review, Stop while queued |
| Finder | Fixed Finder launch/search workflow with query readback | Earlier actual `sf.webm` search; real Gemma planning checked separately | Current packaged run, absent file, Unicode/spaces, multiple windows, selected search scope, focus loss; never claim file exists from query readback |
| Calculator / Voice Memos / VLC | Installed-app discovery and bundle-ID launch; generic supported AX controls | Earlier launch observations | Launch and control are separate; qualify each app version. Voice recording and media playback require observable effect, not launch alone |
| Google Chrome | Exact reviewed HTTP(S) navigation in a new tab; selected-document bounded static text/links | Earlier loopback navigate/read marker passed | Current package/version, many tabs, Unicode, secure field, modal dialog, redirect, changing tab/window/focus, Stop/sleep, form fixture; no broad form qualification yet |
| Safari | Same restricted navigation/read contract; direct AXTab/radio selected identity | Pure contract tests | Actual Safari native fixture matrix remains unqualified; unsupported layouts must fail safely |
| Other browsers | App discovery/launch may work | None for browser-specific navigation/read | Browser adapter explicitly refuses ambiguous/unsupported browser names. Generic AX controls must be individually reviewed; do not advertise browser parity |
| Custom canvas / inaccessible app controls | Generic observation can return limited evidence | None for full control | Refuse unobservable targets. No coordinate fallback, visual-agent or screen-capture qualification is implied |
| Local files | Explicit selected scopes, text/PDF/OCR/plain .eml reads, bounded search, reviewed single-file move, typed document generation | Component and packaged fixture evidence in release log | Actual Office rendering, provider/volume/corruption matrix, complex PDFs/MIME and broad document layout remain separate |
| Calendar / private sources | Optional selected calendar context; explicit exported files | Pure synthetic tests; no personal account qualification | User-specific permission and readback; no Notes/Messages/WhatsApp databases or account access implied |
| Keyboard access | Opt-in registered quick access and global Stop | Registration/controller tests | Physical delivery, shortcut collisions, multiple spaces/displays, app focus, sleep/relaunch matrix remains open |

## Controlled browser fixture

Start with Python standard library only:

```bash
python3 Scripts/browser-qualification-fixture.py --port 0
```

The first JSON line reports a random loopback port, per-process token, fixture URL, independent state URL and the only accepted synthetic form value. Keep the process running during the test, then stop with Ctrl-C. It binds `127.0.0.1` only, requires an exact loopback Host header, logs no request paths/bodies, uses no external assets/scripts and keeps state only in memory. It is a development fixture, not part of Relay's inference runtime.

Routes use the startup token:

| Route | Purpose | Expected independent outcome |
|---|---|---|
| `/fixture/TOKEN` | Static Unicode marker, relative link and labelled text form | Reads show `Relay browser fixture · Café 🌍 · مرحبا`; editable sentinel excluded from `browser_read_page`; submission count0 |
| `/next/TOKEN` | Exact second destination marker | Only a separately reviewed navigation may certify this URL; marker `NEXT_PAGE_MARKER_456` |
| `/redirect/TOKEN` |302 to local next page | Exact requested-URL verification must return uncertainty/refusal, not certify original destination |
| `/secure-field/TOKEN` | Empty synthetic password input | Reader refuses secure control; never enter any password |
| `/submit/TOKEN` | Form POST, accepts exactly `Relay synthetic note 123` | Requires explicit test form instruction/review, fresh AX target and readback; count increments once, result303 |
| `/result/TOKEN` | Visible synthetic submission outcome | Applied value matches exact fixture string and count1 |
| `/state/TOKEN` | JSON oracle independent of Relay | GET/reading/navigation must not increment count; form submit expected exactly1 |

Do not supply personal text. Server rejects all values except the exact synthetic note and body lengths over512bytes. It performs no file writes. The counter does not prevent duplicate posts: this intentionally detects accidental repeat clicks.

## Execution matrix for each installed supported browser

Record browser version, OS version, exact Relay build hash/signature, fixture port/token and initial count0. Root agent/operator should perform UI actions; API requests to `/state/TOKEN` serve only as the independent oracle, not as substitutes for Relay using the browser.

1. Ask Relay to open exact fixture URL in the named browser. Review exact URL/browser. Verify a new selected tab, unchanged prior tab, exact destination and visible Unicode marker. State stays0.
2. Ask Relay to read that exact current page. Verify marker and relative link; editable sentinel must not appear in returned static text. State stays0. Preserve original field value until the explicit form step.
3. Explicitly request filling only `Synthetic note` with exact allowed synthetic text; inspect review and field readback. Do not submit yet. State stays0.
4. Explicitly request pressing `Apply synthetic note` once; review fresh target. Verify visible result and independent count1/value. Never infer submission from field entry or button dispatch alone.
5. Repeat navigation/read in a window with many tabs, at least two windows, and restored foreground focus. Ambiguous selected identities must refuse.
6. Negative paths: switch tab/window or foreground app while paused at review; edit value after preparing review; disable/remove target in a disposable variant; Stop before dispatch. No unreviewed or stale mutation. Inspect state before any retry.
7. Open redirect route with exact URL review. Observe changed URL and uncertainty; do not accept it as original destination verification.
8. Read secure-field route without entering anything. Expected refusal; state unchanged. Do not grant/request credentials or bypass security UI.
9. Check missing/revoked Accessibility permission on an explicitly disposable test setup, OS sleep/resume or expired workflow, browser unavailable, malformed URL and unsupported browser name. A negative result should include concrete recovery, not a success claim.
10. Repeat offline against loopback only after user-managed connectivity isolation. No current result establishes this physical offline gate; no external website is needed for fixture coverage.

Stop after the first unexpected mutation or mismatched oracle. Record partial effects and exact reproducible case. A rerun can demonstrate recovery, but does not erase the first failure.

## Automated coverage added

`BrowserCompatibilityMatrixTests.swift` exercises all eight identity-presence combinations against full and scheme-omitted addresses, exact port/host/path/token/query/fragment distinctions,100-tab direct AXTab/radio selection with ambiguity/incompleteness refusal, Unicode byte bounds and literal relative link encoding. These are pure contracts, not actual browser control.

`Scripts/Tests/test_browser_qualification_fixture.py` checks fixture Unicode/assets/form isolation, exact accepted value and independent counter, wrong Host/unknown route/body budget, redirect and empty secure-field route. Run:

```bash
python3 -m unittest discover -s Scripts/Tests -p 'test_browser_qualification_fixture.py'
```

No live qualification or test pass is claimed merely by adding this harness. Root owns execution logs and updated evidence.

## Current Chrome qualification incident — unresolved, do not count as pass

During the current native qualification attempt, root reported that a reviewed navigation to `/fixture/TOKEN` failed the post-submit tab identity check, and the visible selected destination was `/submit/TOKEN` with the fixture's synthetic-note rejection text. No form submission was authorized. The old oracle reported accepted `submissions=0`; that only proves the allowed value was not accepted. It did not count rejected POST attempts and therefore cannot establish that no submit request occurred. The native observation did not expose an HTTP status, so the incident status is unknown. The precise sequence and cause require preserved native/Activity evidence. Source maps the note-rejection text to400 and other early rejection to403, but source mapping is not an observed status.

Do not retry the form route or waive selected-tab identity checks to obtain a pass. Fixture schema `relay-browser-v2` now adds `postAttempts`, `rejectedPosts`, `getRequests`, and a bounded32-entry history of method, fixed known route label and HTTP status. No raw path/token/query/body/header is retained. All POST attempts count before validation, including rejected attempts; accepted count stays separate. These counters cannot recover earlier requests from an already-running v1 process. Preserve the old process and evidence before replacing it.

The new `/reading/TOKEN` route has the same Unicode marker and a relative link, with no form or editable controls. It can isolate navigation/read transport behavior without placing a submit target on the page. Even successful form-free navigation does not close the prior incident or qualify form-bearing pages.

Suggested transport diagnostics: verify exact application Activity calls; reassert qualified address focus immediately before commit; investigate a target-bound advertised AXConfirm action instead of queued process-wide Return, failing closed where unavailable. Never claim that posting a key was acknowledged by the destination control. Keep the current exact window/tab/document/readback checks and independent HTTP audit. The event cause is not proven by static review.

Fixture v2's six Python tests passed in3.069seconds (`/tmp/relay-browser-fixture-v2-tests.log`). This verifies the oracle implementation and routes; it does not qualify Chrome/Safari navigation.


Browser commit hardening in source: the adapter now rechecks selected tab, native address focus and exact reviewed address immediately before commit. It requires the qualified native address object to advertise exact `AXConfirm`, and performs that action on that same object. There is no process-wide Return fallback. Unsupported controls fail with bounded technical AX action-name diagnostics and explicit manual confirmation recovery; a new tab/entered address may already exist. This narrows compatibility intentionally until actual target-bound confirmation is qualified in each browser. The current native incident remains unresolved and cannot be converted into a pass by this source change.

## Latest automated checkpoint and final source critique

Root reports335 registered Swift tests across55 suites passed in2.678seconds (`/tmp/relay-release-gaps-browser-tests.log`), including the Safari bootstrap and target-bound address commit contracts. Ten Python tests passed in3.089seconds (`/tmp/relay-release-python-v2-final.log`), covering release gates plus fixture v2. These do not prove native browser event ordering or end-to-end Safari compatibility. Root owns the final package and v2 native results.

Final review identified a logical identity gap in the optional hidden-tab bootstrap: an AXTab object absent from an original zero-tab snapshot may be the previously hidden old logical tab, newly exposed after the tab bar appears. A user switching back to that tab between New Tab and post-inspection could pass the object-not-in-snapshot predicate. Therefore this predicate alone does not prove a newly created logical tab. Automatic URL entry on this bootstrap path should remain disabled/unqualified unless an independent logical identity proof is added; manual tab-bar/second-tab recovery preserves the stronger ordinary original-tab check. Native Start Page-specific proof would require separately justified bounds, not a pure Boolean test.

Target-bound `AXConfirm` removes the process-wide Return fallback and preserves exact address/window/tab/focus/readback checks. Earlier Cmd+A/Delete/text events are still process-wide with a check-to-dispatch interval. Source checks narrow the risk but cannot establish atomic destination delivery. The unresolved form incident and native v2 HTTP audit remain release gates; tests alone must not convert them into browser-control parity claims.


The unsafe automatic hidden-tab bootstrap was removed before final qualification. No automatic New Tab/address entry/confirmation occurs when the original selected tab cannot be identified. Safari hidden single-tab navigation is explicitly unsupported with manual recovery: open a blank second tab or show the tab bar, then retry. The bounded zero-direct-tab content-group distinction remains, but cannot invent a selection. Ordinary visible-tab navigation still requires one known original selected tab and a distinct new selected tab. The prior335-test checkpoint included the now-removed bootstrap tests; root must record a fresh post-removal suite count.


Final entry hardening in source: URL entry now also uses target-bound `AXUIElementSetAttributeValue` on the qualified native address object. The adapter preflights a successful AXValue writability query, true writable flag and exact advertised AXConfirm before sending any destination payload. Cmd+A/Delete/Unicode URL-key transport and its helper were removed; there is no keyboard fallback. Exact readback, address focus and original/new selected-tab/window checks occur after setting and again before confirmation. Setter failure is reported as uncertain partial address state, never as proof of no effects. Fixed Cmd+T/Cmd+L remain only for browser chrome; native qualification of the narrower direct-entry contract is still required. Earlier incident evidence remains historical, not erased.


Reader adapter alignment in source: Safari's native zero-direct-tab content AXTabGroup is now distinguished by the same bounded ordinary-Safari window and complete direct-child-role contract. Reader skips selection validation for that content group but still descends into it to locate the web document. Every actual tab-bearing group still requires unambiguous direct selection, exactly one selected tab and one focused matching document. Hidden single-tab layouts still cannot invent a selection. Plain URL mismatch now explains that an already-requested opening requires `browser_navigate` with destination review; security/authentication and missing-title failures never recommend automatic navigation. Two pure reader regression tests cover these distinctions; root owns fresh full-suite and native qualification.

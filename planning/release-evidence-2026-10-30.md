# Relay alpha expansion — evidence and remaining work

## Latest release-gap checkpoint — 30 October 2026

Current source passed **354 tests in 56 suites** in 4.919 seconds (`/tmp/relay-release-final-tests.log`); optional native/hardware cases remain separate. Ten Python fixture/release tests passed. Five real Gemma GPU tests passed in 34.288 seconds with explicit float32 activations; two long literal-copy payloads matched UTF-8 exactly with 6000 bytes of additional context. The corresponding two CPU copies passed in 41.225 seconds; GPU copies took 13.597 seconds in this controlled invocation, not a universal performance guarantee. The same local two-step inference test passed in 1.852 seconds when launched inside a network-denial sandbox; a loopback connection negative control failed inside that profile and succeeded outside. No system network interface was disabled; this does not qualify all out-of-process macOS services or a physical airgap.

The native KV-state reuse experiment was removed after the actual SDK/model emitted empty tool IDs requiring application repair. Exact-projection safety guards refused retention. Each completion uses a fresh native session; the useful latency fix is removing two redundant informational completion turns. Lifecycle cancellation and monotonic inference budgets remain, with regression coverage.

Browser URL entry now uses target-bound writable AXValue plus advertised AXConfirm; queued URL keystrokes are removed. Safari hidden-tab identity absence fails closed with recovery. Live broad-browser qualification remains open after the preserved Chrome incident and external Chrome activity. Current package/native synthetic-speech verification is recorded in the end-of-file update below; public release still needs owner Developer ID credentials and actual hardened/notarized qualification.


30 October 2026. This is a development alpha, not a signed public release or a claim that every Sentient workflow is complete. The full requested inventory, dependency order and corner-case matrix are in [the roadmap](sentient-gap-roadmap.md).

## Current integration status — fourth source checkpoint, third packaged candidate

The current source passed **309 registered tests across 51 suites in 2.282 seconds** (`/tmp/relay-final-current-tests.log`). This is deterministic integration evidence, not a live task-completion denominator; opt-in model/desktop cases remain separately reported. The earlier 269/45 checkpoint in 2.031 seconds (`/tmp/relay-documents-resume-tests.log`) qualified the third increment's source at that time.

The **third candidate was packaged** with ad-hoc signing and strict signature verification. Actual local-model chat created Unicode DOCX and values-only XLSX artifacts; independent document/workbook oracles checked their contents. [Native artifact result](native-artifacts-verified.png). The prior third-candidate real Gemma CPU suite passed **4 tests in 49.422 seconds**. This is historical invocation evidence, not a hardware latency benchmark.

The **fourth source checkpoint is not yet packaged**. It adds selected mail-export parsing, optional explicitly prepared semantic retrieval, shared private state writes, canonical overwrite checks, strict raw numeric validation and checkpoint/early-response repairs described below. The current-source model invocation completed **14 tests across 7 suites in169.712seconds** (`/tmp/relay-current-gemma.log`), containing **four actual Gemma checks** with reported durations11.858,63.179,56.454and38.217seconds. The remaining tests in that invocation are supporting checks;14 is not a count of actual-model tasks. No live desktop action was dispatched by that suite. This run preceded the final non-schema document/artifact safeguards below. The fourth package build is running (`/tmp/relay-final-current-build.log`); no successful package result is claimed yet. Native sentence embeddings have never been invoked during this qualification; fake backend tests establish mechanics only. No microphone recording, audio playback or native embedding availability/quality/offline behavior is claimed. Earlier native/browser evidence remains tied to its stated build.

### New foundations in source; integration and live gates remain

| Foundation | Implemented scope | Still required |
| --- | --- | --- |
| Local voice input | Explicit start; on-device Speech required; no capture/permission at initialization; bounded transcript/duration, cancel/close/Stop teardown, separate transcript review and explicit append without autosend | Test real consent/cancel/device/language/offline paths with explicit user authorization. Optional read-aloud is implemented and its installed-voice UI was checked separately; actual playback remains unqualified. No microphone permission was requested by this review. |
| Scoped file search | Bounded literal filename search in selected scopes; entry/depth/time/output limits and omission notices | One disposable same-directory model-driven rename passed with native approval and independent byte/hash oracle; wider live UI regressions remain. It is not unrestricted whole-disk search. Optional semantic content ranking is a separate fourth-source feature described below. |
| Preview/review file move | One regular local file up to64MB, same filesystem, writable parent scopes on both ends, exact short-lived one-use ticket, no-overwrite exclusive rename, content/identity checks and live cancellation/grant check | Packaged end-to-end review/Stop/revocation tests. No directories, cross-volume copy/delete, automatic rollback or race-free source-inode CAS claim. macOS-reported dataless placeholders are refused; all provider hydration races are not proven prevented. |
| Scheduled quote preparation | Explicit opt-in; only while Relay is open; source-backed lexical TODO brief, local-day reservation persisted before preparation, bounded restore, reentrancy/busy/low-power/missed-window guards | Packaged app-running/timezone/DST/relaunch/failed-persistence checks. No forced wake, launch-when-quit, model-written daily digest or computer-action dispatch. |
| Local state restore | Bounded schedule restore and persisted inference-reset boundaries; prior context revoked without deleting visible audit | Full corrupted/versioned state and relaunch matrix per component. This does not imply every historical file restore path has a universal schema/migration guarantee. |

Independent source review caught a FIFO MainActor hang before regular-file validation; the helper now opens nonblocking and rejects the FIFO. Canonical hidden-parent aliases are rejected. Review also confirmed voice draft preservation and cancellation integration. The move autoload/configuration exclusion now uses consistent component canonicalization and has alias/case regressions; no review button may unlock security administration, financial actions or executable installation. See [implementation critique](implementation-critique.md).

## Implemented in this increment

| Capability | Implementation | Evidence and limits |
|---|---|---|
| Readability/design | White primary text, bright secondary text, larger operational details, restrained surfaces; clearer setup buttons/recovery | Native visual walkthrough recorded below. Full VoiceOver/text-scaling matrix remains open. |
| Browser navigation/search | Exact reviewed URL/browser; new selected tab; focus and identity checks; literal encoded search | Pure validation/policy tests. Live Chrome/Safari qualification remains open; strict redirects/authentication return uncertainty rather than false success. |
| Browser page reading | Selected document URL, tab/window/document identity before/after, text+safe links bounded to12KB total | Five pure tests. No scripts, network calls or editable values. Live adapter qualification remains open. |
| Local knowledge | Explicit bounded indexing, lexical source-backed search, stale/revoked/deleted source checks, inspect/forget/clear/export | Six component tests; hashes detect same-size/content replacement. Coverage omissions disclosed. Optional semantic ranking is implemented in the fourth source checkpoint with fake-backend evidence only; no background ingestion or native retrieval-quality claim. |
| Source revocation | Stop/invalidate, cancel index, purge knowledge/suggestions; discard prior derived inference context after in-flight work settles | Executor regressions cover late results and relaunch. Visible local chat/Activity retained with explicit notice; revocation is not an erase-all command. |
| OCR | On-device Vision for selected images and scanned PDFs | Real generated-image and scanned-PDF tests; three-page PDF fallback limit. No screen capture or vision-model qualification. |
| Documents | Native PDF/RTF generation, scoped destinations, exact overwrite review/state fingerprint, byte+extracted-text readback | Real PDF/RTF roundtrip and tool integration tests; third packaged candidate additionally created Unicode DOCX/XLSX through actual chat with independent content oracles. No rich editing or pixel-perfect document-layout claim. |
| Quick context | Opt-in CmdShiftSpace, explicit selected-text draft, provenance/secure-field checks, preserves existing draft | Five registration/controller tests use injected callbacks. Live shortcut/selection qualification is separate. No double-tap or keyboard monitor. |
| Global Stop | Opt-in CmdShiftEscape Carbon registration; collision/failure handling, no keyboard capture | Focused callback/registration tests. Stops new dispatch; cannot undo an action already sent. |
| Menu-bar access | Launcher, current readiness/run status, Stop, Quit | Native menu; no notch overlay or independent cursor claim. |
| Writing preferences | Editable tone/length/instructions, explicit Save approval, clear/export, local sample storage | Five tests; unsaved data excluded from model context. Samples are not automatically injected as instructions or used to claim a learned persona. |
| Calendar | Explicit EventKit grant and calendar selection, bounded read-only ranges, busy/cancel/scope-drift returns no verified read | Five pure tests; no live permission granted or personal events fetched during this increment. macOS permission is broader than Relay's read-only tool, clearly explained. |
| Suggestions/brief | Opt-in source-quoted TODO/action-line suggestions, dismiss, stale-source purge, draft-only handoff; app-running schedule foundation added in newest batch | Manual baseline, snooze and app-running schedule foundation are integrated/packaged; scheduled preparation was not enabled live. No forced wake, background model digest, email sending or automatic task execution. |
| Diagnostics | Explicit local JSON export with only enum technical states, sanitized numeric versions and aggregate counts | Five tests; no transcript, filenames, source text, personal paths or automatic upload. |
| Model recovery | Pinned SHA/size, unchanged verified-file cache, typed recovery hints, cancellation and conservative install | Synthetic segmented Range/ETag checkpoint, cache and recovery tests. Whole-file fallback restarts after pause; checked completed ranged segments can resume. No fresh2.59GB transfer qualification. |
| Context management | Retain whole current tool protocol, omit complete older segments with notice, refuse oversized active task | Context and executor tests include Stop→newrequest→late tool response. Full local history is preserved. |

## Automated execution

- Integrated checkpoint:134 registered tests across29 suites passed before final download-cache and browser-budget additions. Opt-in live desktop/model tests are skipped unless enabled; registered count is not a live-task denominator.
- Focused artifact+browser-reader suite:12 tests passed, including real OCR and document file oracles.
- Real Gemma CPU suite:three tests passed in37.697seconds against the installed pinned Gemma package. These validate native tool invocation/result consumption, exact file-write arguments with full production schemas, and exact Finder filename planning. They do not dispatch those planned actions.
- Prior live desktop evidence includes actual Finder `sf.webm` search, Voice Memos/Calculator/VLC launch and all seven native Accessibility fixture checks. Those were performed on earlier builds and do not automatically certify newly added adapters.

## Independent critique

Three parallel implementation/review agents worked on separate files. Antigravity was used through its native app for a separate read-only repository review; [captured review](antigravity-review-raw.txt). Findings were reconciled against concurrent source changes rather than accepted blindly. Concrete fixes include selected-tab binding, full identity-traversal rejection, bounded combined browser output, post-save-panel knowledge revalidation, explicit index coverage, late-result context pairing, future-context reset after revocation and truthful Calendar refresh results. [Critique record](implementation-critique.md).

## Outstanding release gates

- Qualify real Chrome/Safari navigation, page reading and supported form controls, including redirects, stale tabs, focus loss, localization and security interstitials.
- Full offline cold-start/task qualification and hardware/latency/resource matrix; current inference is embedded/local, but disconnected end-to-end testing is distinct.
- VoiceOver, larger text, minimum-window and multi-display matrix; new features need live UI regression beyond source review.
- Live CDN segmented-resume/relaunch/fault qualification; native semantic availability/offline/quality evaluation and incremental retrieval; protected Notes/Mail/Messages account connectors (selected .eml exports are separate); structured knowledge; actual local voice/audio qualification; broader scheduled/model preparation; rich document/workbook editing and held-out end-to-end task reliability.
- Stable Developer ID signing/notarization/update infrastructure requires the owner's distribution credentials. Ad-hoc builds can require refreshing the already-authorized Accessibility entry after rebuild.
- Team administration, iOS and Windows require separate projects/qualification; they are not hidden behind a completed checkbox.

Nothing here authorizes or enables background capture, Calendar access, network tasks, hosted inference, automatic sending or purchases. Optional features remain off until explicitly selected.

## Final integration corrections

Live chat initially exposed an 8192-token runtime overflow that the short isolated planning prompts missed. Full action schemas had been supplied in both the native registry and system prompt. The prompt now supplies names/protocol only, schemas remain native, and the conservative byte budget is24KB. Large tool observations are explicitly abbreviated for inference with original verification status retained; full Activity output remains local. A new opt-in real-Gemma test uses AssistantStore's actual production prompt with a synthetic executor and passed in21.902seconds. The original three real-Gemma tests passed again in21.873seconds after removing duplication.

The native walkthrough also exposed test-state isolation: custom temporary Store state paths previously used the default knowledge/style/suggestion files. These auxiliary stores now live beside the selected state file. A regression verifies independent Store directories cannot clear each other's knowledge or reuse approved style. Only the disposable test-workspace index had been populated in this walkthrough; it is rebuilt after the fix. No personal source index was ingested for testing.

Final deterministic suite after these fixes:145 registered tests across30 suites passed in1.158seconds; opt-in model/desktop cases are separately reported, not implied by that count. Settings entry routing now uses an explicit sheet destination, tab changes reset scroll position, and primary setup buttons use white text on a darker blue surface.

## Sleep/wake and final recovery increment

The machine resumed after the01:44→10:28interval. The selected-page reader had already verified the synthetic marker; subsequent model summarization timed out after suspension. This interval is not a CPU latency measurement. Failed/Stopped responses now retain bounded verified partial outcomes and artifacts while keeping failure/stopped status. Browser input has a30-second wall-clock expiry checked before every key/text dispatch and progress loop, preventing stale typing from resuming hours later.

Calendar selection changes, explicit clearing and permission loss now stop/reset derived future inference context, including a permission check at dispatch gates. Permission observers only inspect authorization status; they never request access or fetch events. Explicit index Forget/Clear uses the same future-context reset. Visible local audit/history is retained with a clear notice.

Historical morning deterministic checkpoint:154 registered tests across31 suites passed in1.102seconds. New regressions cover partial verified results after inference failure, deadline expiry across sleep, Calendar invalidation callbacks and exclusion of forgotten context from the next prompt. Opt-in live tests remain separately reported.

## Completed live qualification — 30 October, morning

- Final native control runner:all seven checks passed after increasing text-mutation response timeout. Independent fixture JSON confirmed exact Unicode input/result and exactly one click; stale/disabled controls, changed review and invalidated queued clicks were rejected.
- Knowledge UI:explicitly indexed the three synthetic TestWorkspace files, forgot one cached record without changing its original file, reindexed, confirmed process termination, relaunched, and observed **Loaded3local sources**. This verifies current persistence isolation/recovery on this development Mac.
- Full natural-language browser request:local Gemma requested `browser_navigate`, exact localhost destination was reviewed, Chrome opened a distinct new selected tab, full document URL/title and formatted address were verified, `read_browser_page` returned the synthetic marker/link with stable identity, and the assistant replied **Verification marker:relay-browser-2026.** Both tool outcomes were independently verified. This qualifies one local static-page Chrome workflow, not Safari, search-engine redirects or arbitrary forms.
- The Chrome adapter now handles its direct Boolean selected-tab representation and scheme-hidden address display, while the full document AXURL still requires the exact reviewed scheme/host/path/query. Conflicting/ambiguous tab evidence remains rejected.
- Temporary localhost tabs were closed individually and the loopback-only fixture server was stopped. No personal browser tab, Calendar grant, screen/microphone capture or hosted inference was enabled for these tests.
- Quick-access/global-Stop registration could be enabled and disabled in the native UI. A targeted synthetic key probe did not establish physical global-hotkey delivery; this remains unqualified rather than a claimed pass. Both optional shortcuts were restored to off.

Screenshots:[knowledge inspector](knowledge-final.png),[verified browser result](browser-flow-verified.png). Public release signing, the full offline/device/app matrix, broader source connectors and every pending roadmap item remain open.


### Latest packaged build smoke check

`bash Scripts/build-app.sh` completed successfully (production compilation 31.49 seconds); ad-hoc strict signature verification and Info.plist lint passed. The app relaunched and reported Ready after the local model/tool probe. [Voice input screenshot](voice-input-ui.png) records the new sheet at its default size; recording remained off. No public distribution/notarization claim.


### Packaged model-driven rename verified

The actual chat accepted a natural-language request to rename only `TestWorkspace/relay-move-source.txt` to `relay-move-result.txt`. Local Gemma produced the preview/ticket and move call; the native review displayed exact paths, 47 bytes and SHA-256 before approval. After approval, Activity verified the rename and the model returned a completed answer. A separate Python filesystem oracle confirmed source absence, destination bytes including Café/emoji, and SHA-256 `219553d9fa03d612ef5fcd82dd6e0acbfae9c3a5d6a7b39a82d18aaf675a0456`. [Native result](file-move-verified.png). This is one disposable same-directory rename, not broad file-management qualification. A subsequent live fresh-review reversal also passed (see below); the disposable source remains in TestWorkspace.


### Selected-scope search and reviewed reversal

On the same packaged build, a second natural-language request to find `relay-move-result.txt` and rename it back produced `search_files` with the exact scoped result (four visited entries, zero symlinks), followed by a new preview and a distinct approval ticket. After explicit review, `move_file` verified the reverse rename. An independent filesystem oracle confirmed `relay-move-source.txt` restored, `relay-move-result.txt` absent and the original Unicode bytes/SHA-256 unchanged. This was a fresh review, not automatic undo. The synthetic source file remains in TestWorkspace.


## Next increment: explicit audio, snooze and conversation ownership

- Read aloud: session opt-in off by default, explicit installed nonpersonal Apple voice, explicit current assistant response, no autospeech. Queued/playing audio stops on Stop, new request, source/memory invalidation, dictation UI opening, sleep, app close or controller teardown; generation-bound delegate callbacks cannot restart it. Response text is bounded to8KB and never silently truncated. Real disconnected audio playback remains unqualified.
- Suggestions: one/seven local-day snooze, next-prepared-brief return, bounded persisted digest/date metadata only, source revocation/change and clock rollback purge, dismissal wins, reset snoozes. No notification, timer or action is created by snoozing.
- Conversation export: user-selected Markdown/JSON visible-history snapshot, Activity opt-in off by default. Excludes hidden inference messages, configuration, grants and approved memory by construction.8MiB source/12MiB output caps reject rather than truncate; arbitrary Markdown source is fenced. Writer uses private0600 stage with inherited ACL removal before bytes, local-volume check, atomic same-directory installation and byte/identity readback. Precommit failure preserves the destination; postcommit failure reports uncertainty. An existing destination can still change between final validation and rename (no inode-CAS claim). Cloud-managed local folders may sync through macOS; the UI explains this.
- Approved memory editing/deletion now invalidates earlier derived inference context and stops its audio. Visible history remains until explicit conversation reset; this is not a claim of historical secure erasure.

This increment was packaged with ad-hoc signature verification. Native voice catalog/selection, private JSON export, and snooze/reprepare/reset were checked. The final wording-only rebuild completed successfully, and the final app was relaunched. The preceding model-driven search/rename/reversal evidence belongs to the prior packaged checkpoint.


### Native checks for the audio/snooze/export increment

- Voice tab defaulted off. Enabling discovered installed voices; explicit Daniel/en-GB selection was read back. No response was played, no asset was requested and no microphone permission was opened. Read-aloud was restored off. [Settings screenshot](speech-settings-ui.png).
- Native JSON SavePanel explicitly targeted TestWorkspace. Export reported30,628 bytes; an independent Python oracle confirmed valid version1 JSON with57 visible messages, no Activity key, mode0600, and no staging files left. [Export screenshot](conversation-export-verified.png). This is a private snapshot of the synthetic development conversation, not an anonymized support report. It remains as `TestWorkspace/relay-conversation-check.json`.
- An explicit fixture action line produced one suggestion. One-local-day snooze hid it; another manual brief kept it hidden. Saved preferences contained one digest/date record and no source path or quotation. Reset plus another explicit brief restored the card. Suggestions were returned off and snoozes cleared; daily scheduling was never enabled.
- The index temporarily included six synthetic TestWorkspace files during this test. The exported transcript, move fixture and snooze fixture were then explicitly forgotten from the index, restoring the original three cached sources. Original test files remain on disk, selected scope and writable flag unchanged.
- Live QA found misleading empty-state wording for filtered suggestions. The status now reports no suggestions to show rather than claiming no action line exists, with a regression added and237/41 suite green after the fix.


### Final Accessibility refresh and observed first-run refusal

After the ad-hoc rebuild, Relay reported its pre-existing macOS control entry stale. Only that same Relay.app entry was refreshed under the user's prior explicit authorization; no other app entry was changed. Relay then read back Accessibility allowed. The first new native fixture invocation refused an incomplete window-tree review read and did not report success. A second separately launched fixture passed all seven checks: observe, exact Unicode text readback, stale-token rejection, independent JSON+AX click effect with clickCount1, disabled-control rejection, changed-payload rejection, and approval invalidation preventing a queued click. No read-policy weakening or blind mutation retry was added. Timing is plausible but no AX error code was captured, so the first failure is not definitively diagnosed; a future diagnostic-only improvement should record code/role/node path/elapsed without field values. This is limited fixture evidence, not a reliability percentage.

The last source change only simplifies Voice-settings copy by removing internal qualification language. Full offline/audio qualification remains in these evidence documents; it is not a claim added to the product UI. The237-test suite precedes that copy-only change; the final release build compiles it and passed strict ad-hoc signature verification. The existing Relay control entry was refreshed again for that copy-only build, and the final app read back Accessibility allowed and Ready after its local model/tool probe. No other app entry changed. Read-aloud and shortcuts stayed off.


Historical audio/snooze/export checkpoint state: Relay was open on its main conversation with the local model Ready. Optional read-aloud, source suggestions, daily preparation and both shortcuts are off. Microphone/Speech permissions were not requested. The three original knowledge records are retained; no private app/source was ingested. This remains a development alpha with the roadmap gates open.


## Third increment: native document/workbook output and resumable model setup

At the initial third-source checkpoint, integrated tests were green and packaging/live artifacts were pending. The third candidate subsequently packaged and passed actual local-chat DOCX/XLSX creation with independent Unicode content oracles, recorded above; this does not qualify the newer fourth source.

- `create_document` now supports bounded plain-text DOCX using AppKit OOXML export. The generator reopens its own bytes and checks exact semantic text, allowing only CRLF paragraph normalization and one native final paragraph newline. The scoped tool rechecks destination/grant/overwrite state and bounded-readback before returning an artifact. A real temporary DOCX roundtrip includes Arabic, emoji and accented text. Existing PDF/RTF remain supported; rich Word layout, images, tables and editing/import of arbitrary DOCX are not delivered.
- `create_spreadsheet` creates a single values-only XLSX sheet with1000-row/30-column/1MiB content/5MiB archive limits. Native fixed OpenXML parts and stored ZIP/CRC32 need no runtime Python, shell, network or third-party dependency. Strings including formula-looking content remain inline text; there are no formulas/macros/external links. Existing output requires exact one-use review. Runtime verification is package-byte readback, not independent calculation or Office rendering. Long identifiers/exact high-precision decimals should be text; numeric cells use Double/Excel-style numeric precision.
- Independent bundled-Python `openpyxl` and `zipfile` QA reopened three standalone generated XLSX files with typed values, Unicode, ordinary markup, blanks and30-column positions. Literal OOXML escape-looking tokens received standards-compliant underscore protection and an independent one-pass XML decoding oracle; `openpyxl3.1.5` does not decode inline ST_Xstring escapes consistently, so that specific path is not claimed live-Excel qualified.
- Model setup now checkpoints completed32MiB ranged segments using a strong ETag/If-Range, exact Content-Range/total/body bounds, identity encoding and original pinned HTTPS source. The isolated actor owns private single-link partial FDs, incremental SHA-256, versioned bounded metadata and a nonblocking filesystem lock. Restoring hashes the committed prefix; changed inode/size/mtime/ctime, forged paths, links and invalid validators cannot authorize append. Interrupted appends roll back to the previous committed offset while ownership remains trusted. Unknown metadata/partials are preserved/quarantined rather than treated as a model.
- Pause/new-controller206 resume, ignored-range200 full-body fallback, changed-validator one-time full restart and unsolicited/malformed ranges have transport+real filesystem tests. A200 body is never appended to a prefix. A host sending whole-file transfers restarts after pause; the UI explicitly distinguishes it. Disk preflight conservatively requires full-package free space on model/temp volumes, including headroom; low-space resume optimization is not claimed. Final full size and pinned SHA remain mandatory before exclusive installation; existing models are never overwritten.
- Retry waits the previous cancelled operation before opening a checkpoint, so a stale writer cannot continue behind a new request. Successful installation is committed synchronously before async cache cleanup, preventing late Stop from erasing an already installed outcome. No fresh2.59GB real transfer, live CDN failure/relaunch or device low-disk fault test has been performed in this increment.

The third increment subsequently passed the four-test real local Gemma suite in49.422seconds. Optional model tests registered in deterministic totals are not counted as live execution unless separately reported.


## Fourth source checkpoint — integrated, not yet packaged

- Selected mail exports: bounded local `.eml` MIME parsing and scoped reading/indexing of inline plain text. Claimed sender/subject/date remain unauthenticated source claims. HTML, attachments, encrypted content and remote assets are not rendered or fetched; no mail-account/database connector or sending is provided. Synthetic parser/tool tests do not qualify personal mailbox access.
- Optional semantic ranking: off by default, explicit user preparation only; a serial actor holds an Apple sentence embedding and queries cannot initialize it. Synthetic probe, vector dimensions/finite norms, bounded chunks/cache, source-hash provenance and cancellation/generation gates are tested with injected fake actors. Store revalidates current source scope/freshness after awaiting results and retains lexical exact hits/fallback. No vectors persist. No real Apple embedding factory, asset availability, language inventory, retrieval quality or strict air-gap behavior has been exercised; OS-managed assets require separate qualification.
- Private state: a shared bounded local writer stages with mode0600 and cleared inherited ACLs before writing bytes, checks local-volume/regular-file constraints and validates committed bytes/identity. State callers use declared caps; errors are surfaced rather than represented as a successful save. Canonical destination/parent identity checks tighten reviewed overwrites. These are conservative filesystem checks, not an inode compare-and-swap guarantee against hostile concurrent replacement; local OS-managed folders may sync independently.
- Workbook input: the production JSON-string entry point checks original numeric spelling before Double decoding can erase precision. Nonfinite/oversized/overprecise numbers, nonzero subnormals and malformed comma syntax are rejected; long identifiers and exact decimals should be text. Typed values cannot recover already-lost precision. This is values-only output, not formula evaluation.
- Model transfer: checkpoint ownership/rollback/persistence checks are tightened. The progress delegate rejects unexpected HTTP statuses, encoded/error-page MIME bodies and declared/actual byte-budget overruns early; a locked first failure survives URLSession cancellation wording. Unsafe HTTPS downgrade redirects are refused before following. Changed ETag/Content-Range retains the existing single fresh whole-file fallback. Manifest limits align with checkpoint bounds (8GiB,200-byte filename,lowercase SHA,no query/fragment), and newly created model directories request mode0700. Only synthetic transport/filesystem evidence is claimed; no fresh real CDN download was performed.

- Final artifact safeguards: PDF/RTF/DOCX generation reopens and checks semantic text in memory before writing, then checks exact saved bytes. Generic `write_file` refuses four binary artifact extensions rather than putting plain text behind a document filename. Artifact cards identify the parent folder and expose the full path to Accessibility. These final non-schema changes are covered by the309-test/51-suite deterministic run; they followed the actual-model run above.

The309-test/51-suite source result covers this checkpoint. The current-source model invocation completed as reported above; the package build and live native qualification remain pending until separately recorded. It does not supersede the narrower third-candidate artifact evidence with a fourth-candidate live claim.


## Final fourth-package native checks

The release configuration packaged successfully at `build/Relay.app` using ad-hoc signing and strict signature verification (`/tmp/relay-final-current-build.log`). This is a development build, not Developer ID signed/notarized. The relaunched app loaded installed Gemma and passed its structured tool-call probe. Only the existing, previously authorized Relay accessibility entry was refreshed; Settings reported Accessibility allowed.

The packaged accessibility fixture passed all seven checks: independent launch token/observations; exact16-character entry/readback; stale-token refusal; one click with independent JSON effect; disabled-control refusal; changed-review refusal; invalidation preventing queued click. This qualifies the synthetic fixture, not every macOS application.

A natural-language request in the packaged app used `read_file` on the synthetic455-byte `TestWorkspace/mail-check.eml`. Activity showed exact decoded body `The synthetic launch review is Tuesday at 10. Café.`, unverified sender `fixture@example.invalid`, and omission of HTML/attachments/remote assets. Final answer preserved body and identity qualification. The six baseline fixtures were independently SHA-checked unchanged; mail SHA256 remained `7c7aaa89a2ce16aa822848fb1641589e4e3547a66bd1ffccf71f4f6ca8db4d69`. No real Mail account/database or personal mail was used. This is one controlled mail variant, not broad MIME qualification. Screenshot: `planning/native-mail-verified.png`.

Native artifact grid inspection showed both retained DOCX/XLSX cards together, folder subtitles, white text and full-path accessibility labels (`planning/native-artifact-grid-final.png`). Those retained artifacts were created and independently validated in the preceding packaged checkpoint; display in this build does not repeat their creation.

The optional meaning-based search disclosure was inspected with English selected and status off (`planning/native-semantic-off.png`). Prepare was not pressed. No native embedding asset availability, download, relevance, airgap behavior or language matrix is claimed. Microphone recording and actual audio playback were not started. Three prior indexed files remain; suggestions and global shortcuts remain off.

Remaining UX finding: informational mail reading incurred two completion-planning checkpoints, adding model latency and exposing awkward “second checkpoint” phrasing in the response. This remains open; the evidence does not support calling conversation polish or completion latency production-ready. Full public-distribution signing and broad application/browser/device/offline qualification remain open.


## Integrated package and outstanding handoff

The final integrated source passed **362 tests in 56 suites** in5.262seconds (`/tmp/relay-release-integrated-tests.log`). Ten Python tests passed3.119seconds. The development app packaged and passed strict signature verification (`/tmp/relay-release-integrated-build.log`); main executable SHA256 `e0d75a1965a764d86e6d659600c412d0c0cd5451e20e0d0acc132fbad646c301`. This Mac's saved configuration uses GPU with explicit float32 activations and the actual app passed its local engine/tool-call readiness probe. CPU remains the general default for other installs/configurations.

Model preparation now has one owner, protects against repeated Load/late Stop/configuration changes, preserves drafts and disables conflicting controls. Four suspended-load/probe regressions cover those boundaries. Safari's reader now distinguishes its non-tab content group while still traversing that group for the document; actual tab ambiguity, security and URL checks remain strict. The latest natural-language Safari task before that reader repair failed safely without navigation; the subsequent live browser matrix is still open. The final loopback fixture state is saved, and development servers were stopped.

The no-microphone speech diagnostic refused before generating audio because app-process Speech authorization was unavailable, even while macOS showed Relay's existing entry On. Only that existing Speech entry was refreshed and the app fully relaunched; no microphone capture occurred. A separate explicit Recheck Speech access action now checks through the native API and does not automatically start a diagnostic or dictation. The integrated app is currently awaiting that macOS decision. Computer-use safety checks blocked access to `com.apple.UserNotificationCenter`; the human must handle any system consent dialog directly. No protected UI was bypassed, no TCC database or security protection was modified, and no synthetic ASR success is claimed while authorization is pending. Read aloud is off; capture is off; no transcript was sent or saved by these diagnostic checks.

Public release remains blocked: local signing preflight reports zero Developer ID Application identities and no configured notary profile. The signed/notarized path is implemented and tested at its local gates; no Apple upload occurred. A failed ad-hoc hardened candidate was preserved with a non-runnable `.hardened-launch-failed` suffix to avoid advertising a duplicate app. Real certificate-backed hardened launch, notarization, clean-browser operations, physical recognition accuracy/device routes, physical shortcut delivery and a broader offline matrix remain open. The complete preflight is `planning/distribution-preflight.json`; signing instructions are in `planning/distribution-readiness.md`.


## Speech approval follow-up — synthetic recognition passed

After the user confirmed allowing Relay Speech access, the actual app’s separate “Check local speech support” completed successfully: “on-device recognition matched the generated phrase,” 37,159 generated audio frames, 0.8 seconds. This used the microphone-free in-memory diagnostic, with no speaker playback, audio file, chat submission or hosted recognition fallback. This qualifies one synthetic phrase only; physical microphone accuracy, the native ten-second capture deadline and physical offline operation remain unqualified. The earlier Speech authorization blocker is resolved for this diagnostic.

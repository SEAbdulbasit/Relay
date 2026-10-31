# Independent implementation critique — parity expansion

30 October 2026 · Read-only source and local planning review. Owns this report only. No UI automation or source edits. Relay directory has no Git metadata, so no trustworthy branch/diff status can be reported. Existing live-verification notes are historical evidence, not newly repeated tests. Test count is never feature parity.

## Immediate priorities

1. **Browser capability is the largest functional gap.** `MacTools.swift:143–148` opens a reviewed URL and correctly reports an unverified page outcome. There is no structured browser navigation/content/search/form backend. AX observation is bounded and generic consequential controls remain unsupported. Deliver a bounded browser adapter and actual load/origin/content evidence before promising research or browser-task parity.
2. **Knowledge is not implemented by approved-memory strings.** `AssistantStore.swift:312–316,378` adds/deletes explicit reusable facts; file tools read bounded text/PDF excerpts. There is no ingestion queue, provenance-indexed corpus, retrieval/citation validation, stale-source refresh or revocation/deletion pipeline. Implement these as explicit new capabilities, not relabeling Memory.
3. **Tool verification is not task completion.** `AssistantStore.swift:129–151` correctly avoids Completed based on arbitrary verified tools, but still presents model-generated final narrative beside operation evidence. The model can save the wrong interpretation with perfectly matching byte readback. Add explicit outcome checks and partial-result accounting for supported task classes; never restore the old “any verified tool means completed” shortcut.

## Capability gates and concrete edge cases

| Area | Current boundary / blocker | Required next behavior and adversarial checks |
| --- | --- | --- |
| Browser navigation | URL accepted by NSWorkspace is not page loaded. AX may omit origin and page content. | Capture actual tab identity, committed origin/URL, load/error state and bounded content; handle redirects, new tabs, browser closure, login expiry, downloads and offline transitions. A page asking to widen access is untrusted content. Never treat visiting a site as authority to transmit selected private files. |
| Browser forms | Plain text entry is supported; send/submit/security/financial/destructive controls remain manual. Generic review is not a loophole. | Qualify fields, selections, checkbox state, multiline values, autosave behavior, duplicate labels and validation errors. Recheck target/recipient/payload before any supported consequential boundary. Unknown/financial/security effects stay excluded even if a user clicks Approve. |
| Research | No fetch/search/page-reading adapter or independent citation coverage. | Show sources actually read and omissions; detect paywalls, stale pages, unsupported binary content, pagination and conflicting claims. Preserve partial research when a source fails. No invented sources or matching-source-equals-truth claim. |
| Knowledge ingestion | No index lifecycle. Approved facts are a separate existing capability. | Explicit source selection, source identity/content hash, parser/chunker/model versions, bounded ingestion, local embeddings, inspectable queue and removal. Test moved/deleted files, symlink escape, parser failure, huge files, duplicate sources, encrypted/scanned PDFs and malicious embedded instructions. |
| Retrieval and deletion | No search provenance/revocation contract. Existing history can retain old observed text after grant removal. | Bind citations to exact source/version/range; disclose stale/incomplete context. On revocation stop dependent operations, prevent future retrieval and delete derived chunks/embeddings/caches as promised. Distinguish revoking future access from deleting already-retained conversation/history; provide deliberate deletion controls. |
| Task verification | Current evidence certifies a process, query, AX value or payload bytes. Broader intent is not certified. | For file organization verify complete intended input/output mapping, collisions and untouched originals. For tables independently recompute totals and reconcile row counts. For drafts separate prepared/saved/inserted/sent states. Test wrong model payload, partial success, uncertain write, late action completion and changed user constraints. |
| Permissions | AX trust is tested separately; ad-hoc signing can change trust after rebuild. File grants are paths. No screenshots/vision fallback qualified. | Distinguish missing vs revoked AX, inaccessible files, auth challenges and unsupported controls; pause dependent work, preserve outputs and refresh state after recovery. Ship stable signing/notarization before durable permissions claims. Screen capture needs its own justified permission/readiness path if introduced. |
| Offline / local models | Embedded model path has no hosted fallback. Online task actions are allowed. | Test cold restart and local task execution disconnected, model missing/corrupt, long load cancellation, memory pressure and failed backend. Network tasks must pause with partial work when disconnected; never call browser failure model failure. Separately measure runtime inference traffic and explicit download/site traffic. |
| Updates | Build is local ad-hoc; no update channel, signed manifest, rollout or recovery mechanism shown. | Explicit install/update policy, signature/identity verification, compatible model/driver/schema versions, resumable or honest restart behavior and recoverable failed install. Never download/replace during an active mutation. Update app identity must preserve or explain permission changes. Do not claim auto-update merely from a download button. |
| Global shortcuts | `RelayApp.swift:23–36` defines focused-app menu shortcuts only. | Implement and test actual system-wide summon/Stop registration, collision/failure handling, held-key repeat, disabled state, multiple windows, other focused app and Secure Input. Clearly distinguish foreground app shortcuts from global shortcuts. Input Monitoring/Accessibility must not be silently expanded. |
| Proactive work | No scheduler, source monitor or notification lifecycle exists. Earlier PRD excluded it; latest parity request requires a separately recorded scope expansion. | Begin with user-enabled suggestion generation and explicit sources/times. Suggestion generation must not silently execute app mutations. Test stale suggestions, changed recipient/content, duplicate runs, missed schedule, sleep/wake, timezone/DST, low power, offline and model unavailable. Log actual run time and missed work honestly. |

## Promises to reject or qualify

- **Independent macOS cursor:** same-desktop coordinate automation shares real focus/cursor. AX can target some controls without moving the cursor; that is not a separate guaranteed pointer or universal background control. Remote/virtual desktops need a separately implemented transport and environment.
- **Overnight wake:** an ordinary suspended/quit app cannot promise to wake a sleeping Mac and finish work. A future background/helper/scheduling design needs platform feasibility, explicit authorization and missed-run reporting. Current agent availability is not a product scheduler.
- **Mobile parity:** no iOS implementation exists, and macOS AX/browser-control assumptions do not transfer to iOS. Keep a separate companion use case and qualification.
- **Universal Sentient parity:** reference source includes hosted integrations, proactive collection and other behavior incompatible with Relay's settled local-only or excluded-action boundaries. Track each feature as absent, implemented, exercised and qualified; do not clone promises or unlock exclusions through generic approval.
- **Successful suite equals production reliability:** unit tests, real-model planning tests, fixture AX actions and real-app outcome tests are distinct evidence layers. Report each by task/model/hardware/app version, including skipped cases.

## Readability review for current changes

The current native MainView already uses 16pt message/composer text and 14pt controls/supporting text with near-white ink; these source changes move toward the user's request. Actual white balance, clipping, enlarged text and VoiceOver still need rendered native inspection.

| Before / risk | After / acceptance | Why |
| --- | --- | --- |
| Secondary instructions shrink into 9–11pt metadata | Keep actionable instructions/status at readable desktop sizes; reserve microtype for nonessential metadata | “Larger white text” must include errors, progress and permissions, not only the greeting. |
| Brightening every surface/control equally | White primary reading ink with distinct secondary hierarchy and measured contrast | Readability requires hierarchy and focus, not flattening all information into the same brightness. |
| Feature buttons suggest unavailable automation | Capability labels accurately state available, needs setup, experimental or unsupported | A polished screen must not overstate unfinished functionality. |

## Next review contract

For new code, review cancellation and actor reentrancy at every await, fresh source/target bindings, exact approval snapshots, capability restrictions, evidence strength, atomic scoped writes and no SDK automatic dispatch. Keep independent test oracles outside executor claims. Refuse broad success labels unsupported by actual postconditions. This report is a backlog critique, not approval to ship unimplemented features.

## Incremental source review — browser, knowledge and quick access

Reviewed BrowserAutomation.swift, LocalKnowledge.swift, QuickAccess.swift, KnowledgeView.swift and new AssistantStore integration on 30 October. No live browser/selection operation was performed.

### P1 — Revalidate knowledge export after the save panel

`KnowledgeView.swift:92–98` purges before `NSSavePanel.runModal()`, then exports records without another scope/freshness check. The modal runs a nested event loop; a source can change, disappear or be revoked while destination selection is pending. `LocalKnowledge.exportMarkdown():181–184` has no grants parameter or validation and serializes every retained record.

Revalidate immediately after the panel closes, and preferably make the export API require current grants and perform its own purge. Regression: open export panel, modify/revoke a source before returning, then assert its text cannot appear in exported bytes. Do not label a pre-panel snapshot current without explicit snapshot semantics.

### P2 — Silent index truncation undermines search coverage

`LocalKnowledge.extract:211–230` caps text at 65,536 UTF-8 bytes and PDFs at 100 pages, but KnowledgeRecord, indexing status and search/export output do not record omitted coverage. A 1 MB document can be listed as indexed/current while a later phrase is unsearchable without explaining why.

Persist a truncated/coverage field, expose it in source/search/export UI and qualify no-match text when selected sources are partial. Regression: query a phrase after the byte/page limit; response must disclose that omitted content was not searched. The hard limits themselves should remain.

### P2 — Page verification is not bound to the selected tab

`BrowserAutomation.navigate:136–143` accepts any matching titled AXWebArea found below the focused window. It does not require the element to belong to the new selected tab or establish visibility. A browser exposing cached/background web areas can satisfy the predicate with a different document.

Bind to the selected active document/tab and the post-Cmd+T tab identity, using explicit browser semantics or fail closed when unavailable. Regression: another tab already has the expected URL/title, while new navigation fails/redirects; it must not certify the old document. Continue distinguishing destination confirmation from complete load/results.

### Reviewed boundaries that currently look correct

- Knowledge scan is explicit and bounded, lexical rather than advertised semantic embeddings. Search rechecks scope and source hash before returning text. Revoking a grant cancels an active scan and purges records in Store integration.
- Shortcut registration does not capture context or dispatch tools. Capture is separately opt-in, rejects secure/modal ancestors, bounds text, records provenance and checks foreground process stability.
- Selected-text capture preserves a nonempty draft. Capture and draft assignment are synchronous on MainActor, so no await permits an intervening draft overwrite in this path.
- Browser text is sent only after qualified chrome address focus and exact address readback; URL schemes/credentials/control characters are checked. A verified destination is explicitly not search-result accuracy or form submission.

These statements are source review, not live qualification or closure of the edge cases above.

## Integrated release-blocker review — context window and new tools

Current source read on 30 October. No source edits and no live UI performed in this review.

### P1 — New request can inherit an orphaned old tool result after Stop

`AssistantStore.send:109` sets activeContextStart before beginRun waits for the previous task. Stop marks the phase stopped immediately, so a new message is treated as a new segment even while an in-flight old execute is still settling. That old task can append its tool response or reconciliation after the new user message. If context compaction drops the old assistant call, the active tail contains an orphan tool result.

`ContextWindow.prepare:9–13` validates size/count but not protocol well-formedness of the active tail. isWellFormed is called only for optional earlier candidates at line 22. An active-only return can therefore pass malformed native tool history into the SDK. Fix segmentation across the settling boundary: move new-segment start after the previous task is reconciled, or include the complete crossing call/result segment. Validate the chosen active history before inference and preserve the new user request on failure. Regression: delayed tool result → Stop → immediate new user message → tiny context budget; assert complete call/result pairing and that the new request proceeds.

### P2 — Calendar tool can certify a read that never ran

`MacTools.swift:169–176` awaits CalendarSource.refresh then treats absent error as successful verification. `CalendarSource.refresh:77` returns immediately when another read/request is loading; lines 100 and 121 also return when scope/revision changes without a structured failure result. The caller can report verified cached/empty events despite not executing its requested range/scope.

Return an explicit successful read snapshot including range, selected calendar IDs and revision, or throw busy/cancelled/scope-changed. Build the tool response only from that returned snapshot. Test concurrent GUI refresh and model read with different ranges, and selection changes during refresh. Cancellation or changed-scope empty results must not mean verified “no events.”

### P2 — Forgotten index excerpts remain visible in suggestion cards

`KnowledgeView.swift:68,80` forgets/clears index records without purging ProactiveSuggestions. The same mounted view can retain old source excerpts in suggestion cards until a later onAppear/explicit preparation/Put in draft. Put in draft does revalidate, so stale content is not dispatched through that path, but Forget/Clear does not remove the already-derived visible suggestion text.

Observe index-record changes or centralize index mutations to purge derived suggestions immediately. Clear cached search results on grant/record changes too. Test Forget/Clear while a generated brief and search result are visible; old text should disappear without requiring a navigation cycle.

### Earlier findings now addressed in current source

- Knowledge export purges again after NSSavePanel returns (`KnowledgeView.swift:165`), closing the pre-modal-only freshness gap.
- Indexed record coverageNote now records PDF text-layer/page and byte truncation and is included with matching excerpts and export. It is still useful to qualify no-match text when any source has partial coverage.
- Browser verification is bound to the original window, different newly selected tab, focused page ancestor and exact address/page URL; no arbitrary background descendant can certify success. Browser AX layouts without the required semantics fail closed. No live browser qualification has been added by these source changes.

### Current readability assessment

MainView uses near-white reading ink, 16pt conversation/composer, 14pt controls/evidence and larger heading text. This satisfies the requested direction in code. No rendered contrast/white-balance, minimum-window clipping or VoiceOver approval is implied. Preserve errors, permissions, missing-model status and Stop at these readable sizes when adding features.

## Review closure and narrow fixes — latest status

The historical sections above describe findings at their inspection time; this latest status supersedes them where explicitly closed.

- **Context protocol boundary:** root expanded the active segment backward until it includes complete tool pairs, rejects irreparable malformed history before inference and added crossing-boundary tests. No new completion claim is inferred from compaction.
- **Revoked data in future inference:** grant removal now stops dependent execution, stores a pending context-reset boundary, clears the old objective and retains visible local audit with a notice. After the old task settles, only explicit new user messages after the boundary are retained for future inference; late old tool/assistant results are excluded. The pending reset is persisted/restored, so relaunch cannot restore revoked inference context. Regression checks cover a delayed private result after revocation and a relaunch before reset application. User-approved memory remains a distinct intentional retention mechanism; visible history is not claimed deleted.
- **Global Stop:** new GlobalStopShortcutController is opt-in/default-off, uses registered Carbon Cmd-Shift-Escape with its own RlyS identity, checks callback identity and opt-in state, and invokes only the supplied stop closure. No keyboard monitor, selection capture or model action is introduced. Collision and unregister failures preserve truthful state. Unit coverage uses injected registration and does not prove actual system-wide delivery/collision behavior on the user's Mac.
- **Validation:** eleven focused executor/shortcut tests passed, including both revocation regressions. This is targeted correctness evidence, not Sentient feature parity or a live desktop reliability score.

Remaining actionable review items unless fixed in a later change: calendar refresh needs an explicit request-scoped successful result rather than interpreting an early-return as a verified read; index Forget/Clear should immediately purge visible derived suggestions/cached search results. Full live browser qualification remains necessary after the stronger selected-tab/page verification contract. New page-reading work needs its own review rather than inheriting navigation's qualification.

## Latest integrated verification — prior issues closed

Read the updated sources without running another build (root owns the full-suite run).

- **Calendar early-return finding closed:** CalendarSource.refresh now returns Bool, explicitly false for busy/cancelled/changed scope and true only after successful permission/scoped read completion. MacTools guards that Bool before constructing verified event output.
- **Visible stale suggestion finding closed:** KnowledgeView observes record changes to purge suggestions and refresh cached search; grant-ID changes refresh search. Forget/Clear/revocation now trigger the mounted view update instead of waiting for navigation.
- **Menu bar:** Open Relay, model/task status and Stop are exposed without starting model work. Global shortcut registration remains independently opt-in. Actual registration/event delivery still requires live qualification.

### P2 — BrowserPageReader identity traversal silently omits children

`BrowserPageReader.swift:132` enqueues only the first 100 children but does not reject an oversized child list. The subsequent `cursor == queue.count` check at line 134 can therefore declare the traversal complete and one document unique even if another web area, modal or secure context was omitted after child 100. Unlike content extraction (line 72), identity qualification cannot safely call this a truncated-but-valid read.

Fail closed whenever any identity-node child list exceeds the cap (or otherwise inspect all children within a proven complete budget). Regression: expected page in an early child and a second document/modal after child 100 must not yield a qualified identity. Bounded page content may remain partial with explicit truncation; identity/security context must be complete enough to support the claim.

### Current interface code critique

| Before / risk | Current source / remaining check | Why |
| --- | --- | --- |
| Small low-contrast reading/control text | Conversation/composer 16pt; controls/evidence generally14pt; near-white reading ink | The requested larger white-text direction is materially implemented in code. |
| Stop reachable only through main chat | Main header, menu bar and opt-in registered shortcut paths | Provides access while another application is foreground; actual shortcut delivery is not established by injection tests. |
| New capability controls imply automatic monitoring | Knowledge suggestions explicitly say manual brief; calendar access explains full OS permission but product read-only scope | Preserves honest feature and privacy boundaries. |

No rendered balance, minimum-window clipping, accessibility sizing, VoiceOver, true global delivery or browser compatibility sign-off is claimed from source review.

## Root live-integration follow-up

| Before | After | Why |
| --- | --- | --- |
| Knowledge header shortcut sometimes opens Model due separate state capture | Identifiable sheet destination supplies the selected section | A direct entry point must land in the promised place |
| Settings content can inherit another tab's scroll offset | Scroll view identity follows selected tab | Each section starts at its heading and primary controls |
| Light-blue setup button uses dark text | Darker blue with white label | Meets the requested white-text treatment with readable contrast |
| Full native tool schemas duplicated in system text | Schemas supplied once through native registry; protocol and names in system | Live production prompt exceeded8192tokens although isolated prompts passed |
| Custom Store state paths share default auxiliary source/profile files | All auxiliary files live beside that Store's state file | Test/alternate stores must never purge the user's primary index |

These fixes have deterministic coverage where appropriate. BrowserPageReader's identity child truncation is now fail-closed and selected tab/focused document are bound before/after; its total text+link output is bounded. Live browser compatibility remains a separate open gate.

## Browser identity closure — selected-tab fallback review

Reviewed the exact saved direct-tab fallback and updated reader source after app_discovery's handoff. No source/build/UI changes in this review.

The prior identity-child omission finding is **closed**: browser identity now rejects oversized child lists rather than silently dropping them. The navigation tab scan prunes page web areas, hidden branches and descendant tab controls; it requires complete traversal and one outer tab group. Explicit selected children must map to direct qualifying tabs and cannot conflict with Boolean selection. When AXSelectedChildren is empty/missing, fallback requires known selection/value state for every visible direct tab and exactly one selected tab; conflicting, unknown, multiple or absent selection fails closed. This is a compatibility fallback for real Chrome AX semantics, not a permissive page-label heuristic.

Reader now binds selected-tab identity and focused document ancestry as well as window/process/URL/title before and after extraction. Text and link lists share a bounded total budget. No new blocking issue was found in this focused source read. Actual Chrome/Safari delivery and accessibility variations remain live-qualification work; pure selection tests do not prove browser interaction.

## Sleep/wake release audit — current boundaries

Read-only review while root owns failure-result handling and app_discovery owns browser action deadlines. No source or build changes in this pass.

The observed browser-page read at 01:44 followed by local-model timeout after wake at10:28 is **not a CPU-latency measurement**. Machine suspension crosses wall-clock budgets. Record sleep/wake and actual inference timing separately before drawing model-performance conclusions.

Current AX control references expire after60seconds and are state-checked before mutation. Pending file/button review snapshots are revalidated at approval and dispatch; Stop/steering invalidate them. Embedded inference checks its wall-clock budget before returning an action. Browser keystroke loops need the independently owned action deadline patch to prevent input resuming after a long suspension even when focus still matches. No new generic approval bypass was identified in this source pass.

### P2 — Calendar forgetting does not yet reset future inference context

File-grant removal now resets prior derived model context after cancellation settles. CalendarSource.clear(), calendar deselection and authorization loss clear its events/cache but do not remove earlier read_calendar tool excerpts from AssistantStore.modelMessages. Those excerpts can remain in a future inference window. The UI action is named “Forget calendar context,” which can imply more than clearing the panel.

Either route explicit calendar forgetting/revocation through a source-aware future-inference reset (preserving visible audit with an honest notice), or label the action precisely as clearing cached calendar selection/results while earlier conversation remains available to the model. A regression should read a uniquely marked event, forget/revoke calendar context, start another request, and verify the documented retention behavior. Approved memory and the OS's own calendar data are separate boundaries.

Root is adding verified partial outcomes and artifact links to failed-run final messages while retaining Failed status. Once saved/tested, that addresses the earlier gap where a verified browser read was hidden behind a later model failure. Partial operation evidence must not turn into whole-task success or an unverified summary.

Current larger near-white UI remains a source-confirmed design direction only. Permission/status errors, partial results, cancellation and completion labels need the same readable hierarchy. Live UI testing and real browser compatibility evidence remain separately reported.

## Latest narrow-fix closure — calendar forgetting and sleep/wake

Reviewed saved changes read-only; no additional build or live interaction was run here.

- **Calendar future-context finding closed in source:** selection changes, explicit Clear and transition from allowed to lost OS permission call onContextInvalidated. Store stops dependent work and applies its persisted pending inference reset after old work settles. Explicit Knowledge Forget/Clear uses the same path. Calendar observers check authorization only; they do not fetch events or prompt automatically. Restored prior calendar tool history is invalidated because calendar selection is session-scoped. Visible conversation/Activity remains intentionally retained with a notice; no deletion of that audit is claimed.
- **Partial-result presentation gap closed in source:** Failed and Stop responses now include bounded verified operation summaries/evidence and artifacts where available, without marking the whole task completed. The later inference failure remains Failed. In-flight results are still reconciled separately.
- **Browser post-suspension typing gap addressed in source:** navigation establishes a30-second wall-clock deadline and checks it before each fixed key/text dispatch and navigation progress loop. After the deadline, the action reports uncertain/partial state rather than continuing the URL. This does not certify general wake scheduling or eliminate all platform focus races.

No new blocking issue was identified in this focused source pass. Root-owned tests and actual live qualification must establish execution evidence separately. The overnight suspension incident still must not be used as CPU-latency data.

## R13 independent review — local voice and scoped moves

Read saved helper code only. Other agents own implementation/tests; no build or source changes in this review.

**Voice:** no initial permission/capture APIs or autosend are present. Capability is preflighted, recognition requires on-device support, permission awaits and callbacks are revision-guarded, transcript size/duration are bounded and terminal paths remove capture resources. Locale edits now stop a busy prior session, closing the old-locale-across-permission-await issue. Integration must explicitly stop/cancel on voice UI close, quit and global Stop: start() returns when recording begins, so cancelling an already completed caller task does not stop the microphone. Transcript must remain separately reviewable and never overwrite a nonempty draft automatically. No actual microphone/permission delivery was exercised by this review.

**Move:** both paths require writable scopes; preview binds source inode/device/content and parent identities, grant fingerprint and expiry; move is same-filesystem and descriptor-relative exclusive/no-overwrite. Post-dispatch verification failures return uncertain without rollback/replay. Found a real blocking issue: opening a FIFO with blocking O_RDONLY before fstat could hang MainActor and prevent Stop. Owner saved O_NONBLOCK with a real mkfifo rejection regression; source fix confirmed.

Outstanding edge check sent owner: raw hidden-path validation must also cover canonical paths reached through a visible parent alias into a hidden directory. A source pathname can still be replaced between final identity check and rename; descriptor-relative rename prevents destination overwrite but is not a source-inode compare-and-swap. Do not advertise race-free moves against concurrent hostile writers. Complete post-checks honestly classify discrepancies as uncertain.

**Search:** selected-root recursion is bounded by entries/depth/time/output, hidden/symlink handling and explicit truncation. Owner reported a nested-search test failure under investigation; no pass or completeness claim should be made until fixed. Root's move integration must invalidate preview tickets and cancel on live scope changes; passing an immutable grants snapshot to a helper alone does not detect revocation.

## R13 final integration review — narrow remaining exclusion boundary

Read-only inspection confirms move tickets are one-use, bounded to20 pending/120seconds and always reviewed. After asynchronous hashing, the helper calls the product's live grant/effect-generation predicate immediately before exclusive rename with no intervening await. Stop/revocation clears tickets and increments generation. The FIFO and canonical-hidden-alias fixes are present; owner reports nested traversal and writable-parent namespace regressions fixed. This does not make rename-by-name a source-inode CAS against concurrent hostile writers.

Voice UI disables language edits while busy, cancels on disappearance, exposes explicit transcript use/append and preserves existing draft text without autosend. Store Stop cancels capture. Scheduled preparation reserves and persists the local day before its synchronous preparation callback, has a reentrancy guard and bounds restore reads. It remains app-running source preparation, not Mac wake/unattended computer execution.

**Do not reopen the old Terminal handler finding:** current open_file validates both explicit and default resolved handlers against the qualified document/media bundle allowlist. A plain .txt cannot currently be routed through this tool to Terminal. No current bypass was identified in that path.

### P1 — Move can bypass the existing configuration-write exclusion

The new move helper accepts visible regular files with writable parent scope, without an ordinary-document/autoload destination policy. Given explicitly writable source and `~/Library/LaunchAgents` folder grants, a visible text file containing launchd configuration can be renamed to `~/Library/LaunchAgents/name.plist`. The existing write_file tool excludes .plist/config output, but move_file can reach that effect. A launch agent may take effect on a later login/load; this is not evidence that the move immediately executed code.

Writable scope and generic review must not unlock unsupported security administration or code installation. Add a narrow canonical destination/source policy for known autoload and security-critical configuration locations, or qualify ordinary document/media types consistently across mutation tools. Test visible aliases resolving into those locations. Do not indiscriminately ban moving normal documents merely because they are text or because any app could theoretically interpret them.

No source/build/live UI changes were performed by this review.

## Latest packaged checkpoint — R13/Q06/P03 status clarification

Root reports207 registered tests across37 suites green, ad-hoc packaging complete and one actual model-driven same-directory rename verified by independent source-absence/destination-byte/SHA-256 oracle. This closes the earlier integrated-failing/unpackaged status, not the broader organizer qualification. Voice input's native sheet was smoke-checked with recording off; no actual microphone/Speech grant or recognition is established. Scheduled app-running quote preparation is packaged but was not enabled live. The roadmap now reflects these distinctions.

Speech output and suggestion snooze remain next-batch work pending saved-source review. They must not inherit voice-input consent or source-suggestion qualification automatically. For output, require explicit playback, bounded user-reviewed text, local installed voice only, immediate Stop and no automatic reading of unrelated/private content. For snooze, bind suppression to source/version/id and persist/expire safely across relaunch/time changes without creating reminders or executing actions.

Concrete remaining gaps are the actual missing semantic/incremental retrieval and protected-source connectors; broader browser/form/app variants; DOCX/XLSX; held-out goal verification; physical global shortcut delivery; live microphone/offline language behavior; and public signing/notarization/update infrastructure. Do not convert207 tests or one successful rename into universal Sentient parity.

## Read aloud, snooze and conversation export — current independent review

30 October 2026 · Saved source reviewed; no new audio, microphone, permission, UI or build action performed by this reviewer. The initial integrated228-test/40-suite run had one assertion-expectation mismatch, which root reports corrected. The later root checkpoint passed237 tests/41 suites; the228 run remains historical, not converted to a pass. Root later packaged the code and checked native voice selection, JSON export and snooze, separately from this reviewer’s source read.

| Before / identified risk | After / saved implementation | Why |
| --- | --- | --- |
| Output could start automatically or use an unspecified voice | Silent session default; explicit enable, installed Apple voice choice and per-response speaker action | Consent is specific to playback of the selected existing assistant message; no autospeak or microphone permission inheritance. |
| Old audio callbacks could revive playback state after Stop/new output | Generation/message identity checks and native utterance-token bridge; Stop clears queued/active state | Prevents stale callbacks from changing the next playback's status. Native audio delivery still needs separate live qualification. |
| Speech could continue after memory/source forgetting | Store invalidation stops speech, stops dependent work and resets prior derived future inference context | Removes future inference/audio reuse while explicitly retaining visible local audit. Memory edit/delete now invokes this path. |
| Snooze might become a background reminder or persist private source quotations | One-to-seven-local-day suppression stores only digest IDs/source fingerprints/dates; no timer, wake, action or notification | A snoozed card can return in a later prepared brief after expiry; it is not an executed reminder. Source change/revocation/rollback pruning and dismissal precedence are explicit. |
| Export could silently copy internal model state or unbounded history | Visible-message snapshot, Activity opt-in, explicit private-content warning, bounded input/output and safely fenced Markdown | Hidden model context/settings/memory are not accepted by this export API. An explicit export may still contain private content already visible in messages. |
| File URL was treated as proof that nothing could upload | Saved UI warns that provider-managed folders may sync through macOS | Local file writing does not establish that iCloud/another provider will not transmit the result. |
| New export content is written atomically before chmod0600 | **Closed and tested:** private0600/empty-ACL staging before bytes, atomic installation and readback | A post-write chmod can leave a transient default-permission interval. The saved helper was independently reviewed; eight real temporary-file regressions and native JSON export passed. Existing-target replacement remains a documented non-CAS race. |

The initially suggested reset/read-aloud race was **withdrawn** after checking the exact current source: isRunning includes isClearingConversation, so the existing read-aloud/export guards already refuse that interval. Do not carry it forward as an open finding.

Speech source is bounded to8KB plain text, excludes personal/third-party voices, never uses remote markup or a hosted fallback, and requires exact current assistant-message identity/text in Store integration. Send/resume/dictation/Stop invalidate competing playback. These are source and fake-backend checks, not real speaker/audio-device/offline proof. Output UI uses readable14–15pt operational text; layout and actual voice playback remain unqualified until root's next package/live check.

Historical packaged core now has another actual model-driven path: filename search followed by a fresh reviewed reversal/move, checked by independent Unicode destination bytes/hash and source absence. That strengthens the bounded R13 evidence for the prior packaged core; it does not certify the pending speech/snooze/export batch, bulk organization, provider behavior or arbitrary source-name races.


Final live-check correction: snoozing all matches originally reported no explicit action lines found. The empty state now says "No suggestions to show in this brief" and distinguishes the snoozed count with correct singular/plural wording. This avoids implying that the source action disappeared. A DST/snooze regression now checks that distinction. Full suite237/41 passed after this edit.


Root final native fixture outcome: one initial fail-closed incomplete-review read, followed by7/7 on a separately launched fixture. The reviewer did not infer a definite timeout cause without an AX code, and recommended retaining the current review policy. This observed instability remains a qualification limit, not a hidden pass. Voice UI copy was simplified to explain installed voices, explicit playback and Stop; air-gap testing status stays in engineering evidence.


## DOCX, values-only XLSX and model recovery — latest source review

Current integrated evidence: **269 tests / 45 suites passed in 2.031 seconds** (`/tmp/relay-documents-resume-tests.log`, parent-reported). New packaging/live checks are pending. Current real Gemma tests are still running; this review does not claim their result. No source changes, builds, real model transfer or Office UI execution were performed by this reviewer.

| Before | After | Why |
|---|---|---|
| DOCX creation was unsupported. | Native AppKit plain-text DOCX export reopens generated content and checks exact text with bounded newline normalization. | Provides a real document format while avoiding unsupported rich layout/import promises. |
| Spreadsheet output was limited to text/CSV. | Bounded one-sheet XLSX supports literal text, finite numbers, booleans and blanks, with fixed OpenXML parts and stored ZIP bytes. | Adds typed workbook creation without formulas, macros, links or editing existing files. |
| XML escaping did not protect literal OOXML escape sequences. | Original `_xHHHH_` sequences protect their leading underscore in one pass; generated escapes are not revisited. | Prevents Excel interpreting arbitrary literal user text as an escaped character. Native Excel/Numbers round-trip remains unqualified; openpyxl retains encoded spelling in this specific inline-string case. |
| Interrupted downloads restarted completely. | Strict 32 MiB Range/strong-ETag responses feed private checkpoints; restore rehashes the committed prefix and detects same-size/mtime-restored tampering. | Resumes only a validated representation and preserves full SHA-256 as the installation gate. |
| A fallback could be confused with resumable range bytes. | HTTP200 full-body fallback never appends; a pause restarts that fallback. Changed/missing validators trigger at most one fresh full attempt. | Avoids joining unrelated representations and makes recovery limits explicit. |
| Cancellation/retry could overlap transfer ownership. | New operations await the old task; checkpoint ownership, temporary writes and install checks remain serialized. | Prevents stale transfer work from being presented as current readiness. |

Focused source review found no additional blocker after the XLSX literal-escape correction. Tool integration validates writable scope and extension, binds overwrite review to current output state, checks cancellation/destination again before writing, and reads back generated bytes. XLSX evidence explicitly certifies byte persistence, not independently verified spreadsheet rendering or calculations. DOCX generation is bounded plain text; advanced layout needs visual review.

Remaining qualification is concrete: actual pinned 2.59 GB CDN Range/redirect/ETag behavior; pause/relaunch and connectivity loss; disk exhaustion during append/checkpoint/install; and native Excel/Numbers opening with Unicode and escape-shaped text. Free-space checks deliberately retain a conservative full-size budget on model and temporary volumes, so low-space resume is not optimized. A metadata fsync failure can safely sacrifice resumability after rollback; it does not authorize an unverified installation. Rich document/workbook editing, formulas/recalculation, multiple sheets and broader model lifecycle management remain pending. These foundations do not complete R03/R12 or establish Sentient parity.


## Fourth batch — independent findings and resolutions

Latest integrated suite: **308 tests / 51 suites green**, parent-reported. This section supersedes earlier open source findings where explicitly closed below. Review was read-only: no builds, source edits, native embedding calls or live microphone/Office operations were performed. New package/live qualification remains separate.

| Before | After | Why |
|---|---|---|
| Overwrite review checked the raw path while execution used its canonical destination. | Review reasons and required-review checks use the same scoped canonical destination for UTF-8, DOCX and XLSX writes. | A missing-parent/../ spelling can no longer hide an existing target from review. Actual regression cases check unreviewed denial, unchanged bytes, reviewed success and one-use approval. |
| Knowledge/history/profile state applied private permissions after an atomic write. | Shared LocalPrivateFileWriter creates mode0600 staging and removes ACL grants before any bytes, then checks identity/readback and reports postcommit uncertainty. | Closes transient exposure of indexed mail/source text and other private state, including inherited ACL grants. |
| A generic writer refactor could widen export limits or shrink history capacity. | Generic maximum is32MiB; conversation export retains12MiB through its facade; history32MiB, index20MiB, profile/suggestions262KiB and schedule8KiB have independent caps. | Keeps each public/storage boundary explicit. Existing files are preserved before commit errors; postcommit failures do not falsely promise no effect. |
| XLSX numbers could be rounded before their original precision was checked. | Raw numeric tokens require at most15 significant decimal digits, bounded magnitude and no nonzero subnormal/underflow values; long IDs/exact decimals must use text. | Prevents a generated workbook from silently claiming exact storage of unsupported numeric input. |
| Darwin JSONDecoder accepts malformed trailing commas. | Spreadsheet raw JSON receives strict structural validation before typed decoding, including adjacent-comma/trailing-comma rejection. | Accepted tool data follows the declared JSON contract rather than platform parser permissiveness. |
| Multiple crash-surviving checkpoint records could hit a four-record restore ceiling. | Restore allows at most64 active records and retires unchanged superseded records only after the selected prefix and partial identity validate. | Preserves resumability after bounded interrupted commits without deleting unknown partial data. Retired/invalid archives and orphan data are deliberately not garbage-collected. |
| Mail exports lacked a supported ingestion path. | Selected .eml files receive bounded MIME/plain-text decoding, attachment/HTML/encrypted omission and explicit unverified-header provenance. | Adds a file-import foundation without account access, authenticated sender claims, attachment execution or remote-content fetching. |
| Knowledge matching was exclusively lexical. | Optional explicitly prepared native sentence ranking merges bounded candidates with keyword results; queries never initialize the factory. | Adds a semantic foundation while retaining current-source scope checks and keyword fallback; availability and relevance are not established by fake-backend tests. |

The canonical overwrite and private-persistence findings are **closed in current source**. The shared writer retains conservative destination identity checks rather than claiming an atomic inode compare-and-swap against another writer. Nonlocal-volume rejection does not guarantee a local folder is never synchronized by another provider.

Semantic source review found no additional blocker: source text is absent from the preparation probe; vectors are memory-only; source revocation/change invalidates caches; current grants and content hashes are checked before/after ranking; per-call constraints remain applied. UI uses14–16pt white text and discloses OS-managed assets may need internet during explicit preparation, off-after-relaunch behavior, candidate status and passage limits. Native language availability, disconnected asset behavior and held-out relevance quality remain unqualified. Mail MIME compatibility also remains bounded rather than a complete Mail connector.

**Historical P2 — artifact identity in the interface (closed by final source review below):** MainView artifact cards show only basename and “Show in Finder”; their accessibility labels also use only basename. Different folders containing `report.docx` are indistinguishable without mouse hover. Add a short parent-path subtitle and full-path accessibility description. Root plans to fix this before the next package; it is not yet closed by this review. Adaptive240px cards and15pt filenames are structurally reasonable, but actual narrow-window/VoiceOver layout requires live inspection.


## Final source closure — 309/51 checkpoint

Parent reports **309 tests / 51 suites passed in 2.282 seconds**. Packaging is in progress; this is not current-package live evidence.

| Before | After | Why |
|---|---|---|
| Artifact cards with identical filenames were ambiguous. | Each card includes its parent path with middle truncation, and its accessibility label contains the full file path. | Closes the source-level P2 for mouse/keyboard/assistive identification; narrow-window and VoiceOver behavior still require live qualification. |
| Document content checks could fail after the destination had already been written. | Generated native PDF/RTF/DOCX bytes are reopened and requested text is checked before any write, followed by exact byte readback after installation. | A known generation failure leaves the destination untouched; persistent bytes correspond to the preflighted package. PDF/RTF checks normalize whitespace, so this is text-presence verification rather than exact typography or visual layout certification. |
| Plain UTF-8 writes could masquerade under document/workbook extensions. | write_file rejects PDF, RTF, DOCX and XLSX and directs the model to native artifact tools; four-format regression coverage was added. | Prevents fake file-format claims from a renamed text payload. |

Current focused source review finds no remaining blocker in these changes. Prior artifact-identity P2 is closed in source. No new build or live UI operation was performed by this reviewer.

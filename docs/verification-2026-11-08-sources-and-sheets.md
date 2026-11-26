# Source selection and sheet consistency — 8 November 2026

These are qualified isolated candidates, separate from pushed commit `8c9e43e`. They do not establish full upstream project parity or actual Calendar/native-control acceptance.

The combined 481-input package adds explicit Calendar scope selection, Navigator filename search through the actual selected-directory producer, and consistent image/brief sheets. It passed 1,524 executed declarations with 70 opt-in skips (1,594 registered, 263 suites). Its focused gate passed 201 declarations with three opt-in skips (204 registered, 24 suites). The exact package, seven compiled hosts, logs and prior failure are frozen at `.build/calendar-navigator-test-macro-next/qualified-final/MANIFEST.json`, SHA-256 `67b109dbc04cfbe95cbfb7f9de6842dc1c6c39e49b028b1fe427ccf6be4d1abe`.

The first compile exposed a Swift Testing macro limitation: direct mutating `catalog.publish` calls were rewritten onto an immutable generated value. A test-only correction evaluates each call into a local Boolean before the existing assertion, preserving side effects, order and every assertion. The original failure, source and mixed unqualified host files remain preserved. No product predicate was changed to obtain a pass.

## Calendar scope

The selector exposes the full available list in a bounded scroll area. Checkboxes edit a draft; only “Use selected calendars” commits it through the source's current authorization, loading, catalog-epoch and existing identifier/subset checks. The 20-calendar and 1,024-byte identifier limits remain. Missing IDs require explicit removal and are never matched to a similar title. Refresh, observed authorization changes and delivered database notifications expire the UI catalog; an old draft requires explicit review. Catalog invalidation alone does not stop unrelated tasks when no Calendar scope exists.

The actual pure selector body was tested in an owned AppKit host using synthetic rows, with no CalendarSource/Store instance or EventKit request/read. Six retained captures show row 42 reachable by actual inner scrolling, draft-only editing followed by explicit commit, the 20-selection limit and deselection, stale-list review, missing-ID removal and explicit empty selection. Long titles and the action row remained usable at normal and narrow widths. This reproduces the Knowledge scroll hierarchy; it is not the actual Settings/Store lifecycle. Manifest: `.build/calendar-layout-qa-next/qualified-first/MANIFEST.json`, SHA-256 `ed68be1d0e072df8f031e64c3d0137d8eb042bd5286f5536e60cee8112b1ca57`. A subsequent singular/plural wording correction does not change selection behavior.

Existing headless source tests construct EventKit stores and check authorization status, as before; they do not request access or enumerate real calendar events. Producer-bound immutable event receipts, fresh-query proof, recurrence reconciliation, timezone/all-day/status coverage and actual EventKit acceptance remain separate work. Calendar tools remain held for delegated roles.

## Filename search

Navigator gains only the existing scoped `search_files` capability. Tests use the real selected-directory producer, durable result receipt and Planner handoff. Source drift, grant revocation and Stop at intent settlement retain zero writes and a not-dispatched receipt. Grant revocation follows the existing typed cancellation/stopped path; source drift remains failed. Provider IDs reused in distinct accepted proposal namespaces do not borrow prior receipt authority. These are scripted headless workflows, not actual-model quality or historical-query continuation acceptance.

## Sheet layout

Antigravity supplied an isolated styling candidate using existing Relay surfaces, fonts, buttons and dark editors. Root review and rendering found an expanded-brief overflow. The corrected image sheet has bounded scrolling content and a fixed footer; the brief has a scrolling detail area and fixed action row. Callbacks, disabled rules, source operations and lifecycle behavior remain unchanged.

Four measured own-host captures show positive content viewport height, contained and unchanged footer geometry before/after scrolling, a retained brief heading with expanded agenda, and a reachable task editor. The fixture used exact candidate view bodies with transparent measurement probes, the actual design system and inert synthetic dependencies; it invoked no model, native provider or source read. It does not qualify actual sheet lifecycle, file/window pickers, inference or task execution. Original overflow evidence is preserved separately. Manifest: `.build/sheet-layout-qa-next/second-qualified/MANIFEST.json`, SHA-256 `996b7f7debd8272a4a99fedec8b4e9ea71550dfacdfeca595413e1ad85a49435`.

The separate conversation-continuity candidate is not included in this 481-input qualification. Its reading-position checks passed in an owned fixture, while selectable-text focus isolation still requires the successor gate. No Relay account or login was introduced.

## Conversation continuity successor

Antigravity's follow-up source review identified the actual remount problem: the conversation ScrollView was destroyed on Knowledge navigation and its initial appearance forced a jump to the bottom. Parent MainView state itself was preserved. The isolated correction keeps the workspace mounted, disables its hidden controls/hit testing/accessibility, and leaves Knowledge's existing conditional lifecycle unchanged. Initial tail positioning respects the user's reading state; a new user message resumes tail following. Existing centered search, task, review, steering and permission operations remain unchanged.

The first extracted-source fixture preserved reading position but retained a native selectable-text responder while Knowledge was visible. That result remains unqualified for focus isolation. The successor binds a weak reference to the actual hosting window. Its explicit Knowledge action synchronously requires successful resignation of that window's old responder before mounting the next page. A missing/refusing window leaves the current page visible; an already-visible Knowledge page leaves its filter focus alone. Probe detach/update ownership cannot clear a newer binding. There is no global window lookup, deferred focus reset or window retain cycle.

The successor passed 12 owned captured states: exact earlier reading offsets, preserved expanded evidence, original draft retention, hidden workspace absent from accessibility, actual selectable-text responder resignation to NSWindow, repeated Knowledge navigation preserving its active filter, real NSWindow refusal from an owned veto responder keeping Workspace visible, attached-probe lifetime checks, centered search persistence, hidden assistant streaming, user-message tail following and review auto-return. Exact candidate conversation/layer/lifecycle spans and window probe were used with inert synthetic Store/Knowledge/row dependencies. The first fixture compile's recorder-only namespace error was preserved before correction. No product task, model, native provider or user source ran.

Manifest: `.build/workspace-continuity-next/qualified-second/MANIFEST.json`, SHA-256 `cd6c7ce6600a099ea5bbf0deb12a279ae852b1183cc34a04aae455b1fd9254af`. The actual final source patch is SHA-256 `58c7defa15e1fd8338571151b11d8c4721d59d4e6829e2d551f9f7b4d2b71057`; earlier source hashes and focus findings remain separate. This is scoped presentation qualification. Full product compilation, actual MainView/Store lifecycle, original history and broader Knowledge editing-state retention remain distinct gates.


## November9 explicit Notes backup and persisted reply UI

The reviewed Notes chosen-backup reader/checkpoint/relaunch-Forget overlay8e04fa18 was combined with actual-visible message actions as553 inputs (`a173086681900bdd254d10d4754ffbab1feca21475667cf59b02bc9a6c1cc86e`). It compiled in228.452 s, but its first focused gate failed18 issues before usable Notes rows. No test was weakened. An actual isolated systemSQLite probe demonstrated same-file/URI/NOFOLLOW open14 through the/var alias versus0/readOnly1 through/private/var. A Foundation resolvingSymlinksInPath successor compiled28.707 s but retained the same18issues: an actual Swift probe showed Foundation normalized this temporary URL back to/var. POSIX realpath plus URL construction produced/private/var and actualSQLite open0/readOnly1. The final correction canonicalizes only the system temporary root before creating the private copy; all original no-follow/read-only/digest/source/size/protected-row/checkpoint guards remain.

The553-input POSIX correction plus passive native cost split (`d87555f12f1a5416a332e59912094bc0f66c27e787be213d023f3c412f0272cf`) compiled55.724 s; seven frozen hosts `57d56214bec8b3bda857a2fe5e2a108a09cac62e7dd48040a643f2f83f3d1e20`. All22 Notes declarations passed their actual SQLite/gzip/protobuf/checkpoint/forget fixtures, including1001row capped coverage. Broader focused614Relay/93suites+58Journal/10 still failed12issues in Calendar strict responsiveness and Filename self-expiring metadata gates/physical-slot assertions. Output `6872ab287cfef45f43bcf1b3589ef651b980fca4273bf034fefe92a768b66302`. Notes is an explicit selected standalone backup subset, not live store acquisition, automatic knowledge ingestion or final product acceptance.

A private development553 bundle passed strict ad-hoc verification (manifest `1c7e6cc7b64e266285e880d2c6f0964e4490d5b33b440fb01c35c2293340a9bf`). Actual Home UI now exposes Reply/Quote/Copy in an accessible visible message menu. Root staged a reply to the prior owned arithmetic message, navigated Knowledge→Home with the chip intact, cleared it, selected the exact result sentence in the read-only quote sheet using keyboard selection, and observed the exact-quote chip. After quit/reopening the pending quote remained, and it was then cleared. No message/model request/cloud action was submitted. Local model readiness passed; own-app Accessibility remained absent. Root quit and independently verified no Relay executable remained. This is scoped UI interaction evidence, not a full send/notch or general autonomy pass.

That actual inspection also found horizontal clipping of long raw text inside the quote sheet and a redundant chevron beside its ellipsis menu. A source-only successor synchronizes actual text-document/container width to the real scroll viewport/insets and hides the redundant indicator; qualification is pending. Source text, exact UTF16 range checks, selection delegate, History and Store are unchanged.


The quote-layout successor553 `8b80e63402994824556bd7990294bba04e9e8d6a9d34ba119985834f6061f8e2` compiled119.175 s, host manifest `56af09b1955a067ae06718177bd2f91ebe297f478f10f624663e56df37de4510`. Root packaged it privately (`951a2f5836d09181dd3078becc0514688feaa4bcf0fd63aac1bab0c94e5b9cfa`), opened the actual quote sheet and visually confirmed the previously clipped paragraph wraps inside the viewport. Clicking the read-only text, selecting the exact first sentence with keyboard controls and observing Reply to quote become enabled passed. The sheet was closed without a submission, the app quit and no Relay executable remained. The duplicate menu indicator is removed. This does not close final send/notch or product acceptance.

Root verified every old540 active hash against immutable80d before integrating553 exact inputs;47 paths changed/were added. Unrelated planning status is byte-identical. Active WIP manifest `.build/active-to553-integration-first/MANIFEST.json` SHA `b0ca105d9c024e06b04dff9c0b1aa469479f0cb897dc990017fa936710c2fed6`. The installed/pushed454 build remains untouched. Full default, real OCR, autonomous-control and distribution gates remain open.

The independent selected-Messages backup decoder passed all eight focused declarations on the 560-input candidate `d2b12f21` (build 111.326 seconds, focused 3.399 seconds, output `c24c690abe6d7c33eafb99e583003e6c7490030fb07f588f104b0108cddb4f30`). The owned SQLite tests verify selected chat/date, legacy and modern schemas, plain-text priority, malformed/oversized omissions, UTF-8/UTF-16 boundaries, the latest 80 candidate rows and unchanged source bytes. The archive question flow explicitly allows only the embedded model or loopback LM Studio. Contact names, unsupported attachment/multipart encodings, live Messages, model answer quality and packaged UI acceptance remain open. The exact candidate is integrated into the working checkout; ledger `.build/active-to560-messages-integration-first/MANIFEST.json` (`272602421a2062a1f2f971274b632dd8715d45b58c7ae3531eb997df611d9139`), no push or install.

The optional Messages Contacts attribution and provider fixture successor `057c871b` compiled in 194.239 seconds after a prior actor-annotation compile refusal (`5fa0ae5637196ba14c0cbe3b0e80fe1e4a380ea2e80ad73082d8eabef379f454`). All 15 Messages/Contacts declarations passed (log `52d7cef050763406a6d956846f42ddc2c72eb347ade8142d71c7ccd793a6d0bc`). The Contacts resolver and permission are injected in these tests; no actual address book or permission prompt was touched. The source admits only opted-in incoming handles in the bounded local excerpt, preserves raw model input, and discards results on permission/source/model/Stop changes. Both staged packaging plists passed validation. Actual signed bundle Contacts behavior remains open.

## Integration Progress on 571 Active Inputs: Contacts, Notes, and Providers

The active working checkout has advanced to 571 verified package inputs plus two Contacts packaging overlays (`Info.plist` SHA-256 `b832a25d885502e44a8e2b783ab42a031f9b7fc6ae442abf67db4c664954a21f` and `Release.entitlements` SHA-256 `7cdc92ad2877f763b701be12c18ccba12fc8ec5f68ed40e5f2a54825f5ca6937`), bound by `.build/active-to571-contacts-provider-integration-first/MANIFEST.json`.

### 1. Messages Contacts Attribution (`MessagesArchiveContacts`)
- **Implementation**: `Sources/Relay/MessagesArchiveContacts.swift` and `Tests/RelayTests/MessagesArchiveContactsTests.swift`.
- **Results**: All 15 declarations passed (log SHA-256 `52d7cef050763406a6d956846f42ddc2c72eb347ade8142d71c7ccd793a6d0bc`).
- **Privacy Model**: Contacts resolution is strictly injected and scoped to incoming handles present in the selected 80-row chat excerpt. No ambient address book scan occurs, and resolved names never mutate the underlying raw model prompt.

### 2. Notes POSIX Canonicalization & Database Ingestion
- **Implementation**: `Sources/Relay/NotesDatabaseIngestion.swift`, `Sources/Relay/NotesBodyDecoder.swift`.
- **Results**: All 22 Notes declarations passed on candidate `d87555f1` (host manifest `57d56214`, output log `6872ab28`).
- **Path Resolution**: Fixed temporary URL normalization where Foundation's `resolvingSymlinksInPath` reverted `/private/var` back to `/var`, failing SQLite `open` with read-only flags. POSIX `realpath` now canonicalizes the root directory before opening private SQLite replicas.
- **Coverage**: Verified gzip/protobuf note body decoding, password-protected note omission, deleted note exclusion, and the 1,001-row coverage cap.

### 3. Apple Calendar Scope Selection & Responsiveness
- **Implementation**: `Sources/Relay/CalendarSource.swift`, `Tests/RelayTests/CalendarSelectionDraftTests.swift`.
- **Results**: Tested across 6 AppKit UI captures (`calendar-layout-qa-next`, SHA `ed68be1d`).
- **Capabilities**: Bounded scrollable selector supporting up to 20 selected calendars. Checkbox edits mutate an uncommitted draft; only explicit "Use selected calendars" commits the scope.
- **Responsiveness**: EventKit store authorization refresh was moved from MainActor initialization to query execution, preventing `CalendarDaemon` XPC calls from blocking the main run loop.

### 4. Custom Responses Provider Wire Transport
- **Implementation**: `Sources/Relay/CustomResponsesClient.swift`, `Sources/Relay/CustomResponsesWireCodec.swift`.
- **Results**: All 41 declarations in the owned-provider suite passed (log SHA-256 `292c5609c548cf3e6e3e530164b5ae423535b2ca45d9694b5884fe7e98cc6868`).
- **Transport**: Loopback HTTP validation of exact JSON wire codecs, SSE event streams, tool call / response pairing, and fallback refusals without external cloud network requests.

### 5. UI Presentation & Conversation Continuity
- **Implementation**: `Sources/Relay/MainView.swift`, `Sources/Relay/WorkspaceWindowProbe.swift`.
- **Results**: 12 owned captured states verified (`workspace-continuity-next`, SHA `cd6c7ce6`).
- **Focus Isolation**: MainView binds a weak reference to the hosting window, requiring successful resignation of the selectable-text responder before mounting Knowledge, preserving user reading position and active drafts.

### 6. Parity Candidate Integration (Lanes 1, 2, and 3)
- **Lane 1 (Context Compaction & Knowledge Vault)**: Integrated `ConversationCompactor`, `SidekickInstructionStore`, `KnowledgeVaultValidation`, `CorpusSlicer`, `ConversationHistoryQueryTools`, and `ConversationReplyView`. All 10 associated test suites passed.
- **Lane 2 (Calendar Write Workflow & Mail Ingestion)**: Integrated `CalendarSnapshot`, `CalendarWriteWorkflow`, `CalendarWriteWorkflowTools`, and `MailIngestion`. All associated test suites passed.
- **Lane 3 (Target-Bound Desktop Automation AUT-17 & Sidekick Notch)**: Integrated `TargetBoundDesktopInputAdapter` wired into `MacTools.swift`, `ComputerUseDiagnosticConsent`, and `ReferenceNotchOverlay`. All associated test suites passed.
- **Qualification Verification**: All 2,022 registered test declarations across 319 suites (1,941 Swift Testing RelayTests + 58 RelayJournalTests + 23 XCTest RelayTests) pass with 0 failures across all three test runs:
  - Unrestricted Default (`unrestricted_default_suite_final.log`): **1,934 passed**, **88 opt-in skipped**, **0 failed**.
  - Opt-in MCP Loopback (`mcp_loopback_suite_final.log`): **1,942 passed**, **80 opt-in skipped**, **0 failed** (8 opt-in MCP loopback tests passed).
  - Opt-in OCR Readiness (`ocr_readiness_suite_final.log`): **1,935 passed**, **87 skipped**, **0 failed** (live primer ran and passed in 14.411s, non-live skipped).
  - Historical and intermediate logs are reported separately in `.agents/teamwork/worker_build_test/`.

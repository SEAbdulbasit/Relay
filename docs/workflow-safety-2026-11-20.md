# Relay: history, draft safety, and useful saved results

This pass implements the next priorities from the design audit using three parallel engineering lanes and a coordinating integration pass. The native Workbench design is retained.

## Implemented

- **Restart identity:** journal runs have an explicit persisted owning thread and startup selection. Recovery merges by stable message IDs into that owner and preserves the archive prefix. Time gaps and titles do not decide ordinary restart identity. Legacy ambiguous archives remain distinct; existing duplicate records are not automatically merged or deleted. Restored history confers no execution authority.
- **Conversation Trash:** ordinary deletion and clearing History move conversations into persisted recoverable Trash. Restore returns them to History without selecting, resuming, or sending their content. Explicit destructive factory reset keeps its existing separate semantics.
- **Draft recovery:** title/body edit bindings checkpoint bounded private text before returning. After closing or relaunching, Knowledge offers explicit draft review and restoration. An externally changed, deleted, or trashed original can only produce a newly saved copy. A failed save preserves the checkpoint. Reset/uninstall prevents retiring editors from recreating erased recovery data.
- **Note Trash:** notes move into a persistent local recovery bundle, with their original relative location and bytes. Restore is create-only, preserves exact folder/note identity, and refuses collisions, unsafe paths, symbolic links, and stale source snapshots. There is no automatic expiry or permanent-purge button in this pass.
- **Saved results:** response Save has visible Saving/Saved/Error/Retry states and stable message-based identity. Repeated Save preserves the current edited or moved note rather than making duplicates. Open and Markdown Export reread the exact current saved note. Trashed captures receive restore guidance instead of being silently recreated.
- **Recovery privacy:** draft and note Trash folders are hidden siblings of the vault, outside its shared/indexed/synthesis tree. They remain under Relay's application-support directory and therefore inside its explicit factory-reset/uninstall cleanup scope.

## Verification design

Isolated fixtures cover selected-old-thread → append → restart, long idle gaps, repeated restart, similar/distinct and ambiguous legacy threads, corrupt ownership metadata and explicit reset, no restored execution, Trash persistence, exact note bytes/identity restoration, collision preservation, stale deletion, symlink/path rejection, draft source conflicts and corrupt/failed writes, and repeated/edited/moved/trashed result captures.

All tests use temporary state and vault directories. Live qualification uses only clearly synthetic conversations and notes. No original files, user conversations, credentials, permissions, schedules, or existing historical duplicates are erased or merged for verification.

## Remaining scope

The deeper durable task inspector, shared capability-readiness model, passage retrieval, broad brand consistency across every specialist surface, full accessibility traversal, and physical OS/hardware/live-provider qualification remain separate work. This pass establishes a safer complete saved-result workflow; it does not claim every workflow or every hardware gate is qualified.

Lane details:

- History identity and recovery: implementation and fixtures in `WorkspaceThreadRecovery.swift` / `WorkspaceThreadRecoveryTests.swift`.
- [Draft recovery](draft-recovery-2026-11-20.md)
- [Saved-result workflow](result-workflow-safety-2026-11-20.md)

Integrated results and live observations are appended after validation.

## Integration findings

The first complete run compiled and exercised 2,118 app tests. It reported five failures in the new saved-response fixtures: Foundation's missing-entry error used code 260, while lookup handled only code 4. The implementation now recognizes both absent-entry codes and continues to propagate permission, unsafe-file and other errors. The other app cases, all 58 journal tests, and 24 XCTest checks passed in that run. A fresh complete run of the final source includes two additional Trash crash/long-heading fixtures.

Independent cross-review also removed an unnecessary suspended Save task that could survive reset; Export now rereads and compares the saved note after the destination panel closes. Trash display titles are bounded without truncating original Markdown, legal Mac backslash paths remain recoverable, and incomplete Trash bundles are reported separately without hiding valid recoverable entries. Response capture remains conservative when recovery metadata is unreadable. No assertions were removed or tests disabled to obtain a pass.

## Final automated qualification

The complete serial run of final source passed **2,120 app Swift Testing tests in 330 suites** (122.095 seconds), **58 journal tests in 10 suites** (6.158 seconds), and **24 XCTest checks**. Log: `/tmp/relay-safety-workflow-full-final-2026-11-20.log`. Owned loopback HTTP provider/MCP fixtures and Codex readiness were enabled with the same qualification flags as the preceding reliability pass. The physical/account opt-in gates remain separate; no skipped gate is called verified.

All 32 new isolated cases are included in that run: 8 thread ownership/Trash/reset/no-dispatch fixtures, 8 draft recovery fixtures, 10 note Trash recovery/conflict/path/crash fixtures, and 6 saved-response fixtures. The full run uses serial execution; it is not a claim about timing under concurrent test-suite contention.

The final run reported 79 explicitly skipped opt-in tests. Those OS/hardware/model/account gates remain unqualified. The development app was rebuilt and passed `codesign --verify --deep --strict`. Live verification started with the existing five threads intact; the older synthetic reliability thread still contained its earlier 12 × 13 request and explanation before appending a new synthetic request.

## Live signed-app qualification

- Selected the existing synthetic reliability thread, confirmed its earlier request/explanation remained, and appended a calculator-only request. The existing Codex workspace returned **6 × 7 = 42** with tool evidence; no files or apps were read for that request.
- Saved that response to one real Markdown note and opened its exact reader. The vault changed from one to two editable notes. The response footer retained its saved identity across relaunches.
- Edited the new synthetic note without Save, quit the app normally, and relaunched. The original note still contained only the checked result, while Review drafts offered the exact unsaved text. Restore draft reopened that text in the original editor; explicit Save committed it and removed the pending recovery banner.
- Moved only this synthetic note to Recently deleted notes, restored it, and confirmed its edited body and exact reader returned. No permanent purge was executed.
- Exported the current saved note through the native save panel to `/tmp/Relay workflow verification c81d7a.md`. Independent readback confirmed both its heading and the recovered edited body; export used the current saved version, not the original response text.
- Moved the separate synthetic Design status conversation to Conversation Trash (five threads became four), restored it (five threads again), and observed no task execution or automatic selection caused by Restore.
- Quit and relaunched a second time. The selected reliability thread retained its stable ID, earlier messages and appended answer. History remained at **five threads**, the restored conversation remained present, and the saved-result Open note/Export actions were still available. No new task ran on restart.
- Left the signed app open in Light appearance on the synthetic verification conversation. The two synthetic notes and temporary export remain reviewable artifacts. Existing older duplicate archives were preserved, not merged or erased.

Normal quit/relaunch is live-qualified. Forced power loss, full VoiceOver traversal, every external-app interruption, alternate live-provider accounts, and all 79 skipped opt-in checks remain outside this run. Inline Knowledge drafts are covered; this is not a claim of durable unsubmitted chat-composer drafts. No permissions, credentials, source selections, login items, or schedule settings were enabled by verification.

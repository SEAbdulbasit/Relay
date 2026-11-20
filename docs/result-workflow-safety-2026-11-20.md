# Saved results and recoverable conversation UI — 20 November 2026

This lane owns `MainView.swift`, new `ConversationTrashView.swift`, and response-capture methods in `LocalMarkdownNotes.swift`. It preserves the dirty checkout's earlier design/reliability changes.

## A complete saved-result handoff

The assistant response footer now presents actual local save state: Save, Saving locally, Saved, or a visible failure with Retry save. A successful note does not fade back into an ambiguous Save button after a short timer. The row rediscovers its saved note when remounted. Saving a response uses its stable application message UUID and a create-only `response-<UUID>.md` filename. Repeated explicit saves reuse the same note, including across manager/app restart, and never overwrite the user's later edits.

The capture lookup checks the exact filename in the root and validated local folders. Moved notes resolve their current folder and graph URL. Multiple copies fail closed instead of choosing one. Excessive vault/folder entries also fail with guidance rather than silently truncating the identity search. A capture in the recoverable note Trash cannot be silently recreated: the user receives Restore guidance.

After a successful save, Open note navigates to that exact note through the parent's existing Knowledge departure guard and first-responder handoff. Both Open and Export re-read the current saved note at click time; neither operation saves a new copy. Missing/unreadable notes yield actionable feedback. Export is explicitly the **current saved note as Markdown**, including user edits, through an explicit native save panel and the existing bounded private-file writer. Export errors and successful destination filenames are visible.

All these actions operate on the response/note the user selected. No source grant, model invocation, external sharing, or autonomous execution is introduced. A Saved badge describes local persistence; it does not assert that the assistant's overall task was verified. Artifact cards retain their truthful existing Show in Finder action, without inventing an Open/export capability for unqualified artifact types.

## Conversation recovery affordances

The History footer exposes Conversation Trash, including when no active conversations remain. Per-row deletion is labeled Move to Trash. The former Clear History command becomes Move all conversations to Trash, with recoverability explained in the confirmation. The Trash sheet exposes saved title/message count and explicit Restore; restoration does not select, replay, or resume the conversation. No permanent purge UI is introduced. Persistence/ownership semantics are implemented by the separate history-safety lane.

## Verification

`SavedResponseNoteTests` contains six isolated temporary-directory cases:

1. Repeated Save after a fresh manager instance preserves the exact file and user edits.
2. Moved captures resolve the current folder without a second note.
3. Ambiguous copies fail without changing either file.
4. An oversized failed save leaves no partial note; a bounded retry succeeds once.
5. A symlink at the capture destination cannot replace an unrelated file.
6. A trashed capture requires restore and then reuses the restored content.

Parser and scoped whitespace checks passed. No full build or test execution ran in this lane; the primary agent owns integrated compilation, targeted tests, signature verification and live UI qualification. Native Save/Open/Export/Trash runtime checks and app-quit recovery remain to be recorded by that coordinating pass.

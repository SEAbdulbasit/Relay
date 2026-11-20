# Inline Knowledge draft recovery — 20 November 2026

Implemented in `KnowledgeDraftStore.swift`, `KnowledgeDraftRecoverySheet.swift`, and `KnowledgeView.swift`.

## Behavior

- Actual inline title/body bindings commit a private atomic checkpoint before returning. There is no debounce timer or retiring asynchronous write that can overwrite a newer draft. File writes use the existing fsync/readback/private-file writer.
- Each record retains the original note's exact folder-aware graph URL, relative file path and saved Markdown fingerprint. Checkpoints never write into the saved Markdown note and never confer task execution authority.
- Storage is a **sibling** of the vault (`.<vault-name>.relay-drafts`), outside its export/index/share tree. Records are private mode 0600, limited to 100 files and one MiB encoded bytes per file; editable payload is capped at 512 KiB. Invalid, corrupt and oversized records are retained and surfaced rather than deleted silently. Invalid writes retain the previous committed checkpoint.
- Returning to Knowledge offers Review drafts. Recovery is explicit: Restore draft continues inline editing only if the original fingerprint still matches; a missing, moved, trashed, or externally changed original can only be recovered as a **new** note. Saving a new copy never recreates the old file path.
- The recovery sheet also checkpoints title/body edits. Later/closing preserves recovery. Inline Save a copy allows escape from an external-change save conflict without losing the current text.
- Successful ordinary Save or explicit Discard clears the exact recovery record. Failed save keeps it. Reverting edits to the saved original removes the now-redundant checkpoint. Cleanup failures remain visible; a successfully saved recovery copy is reported accurately even if its old recovery entry cannot be cleared.
- Ordinary navigation retains Save/Discard/Cancel. Cancel preserves text and checkpoint. Missing-note reloads surface the draft instead of leaving an invisible inline editor.
- Explicit factory reset/clean uninstall (`relay.willEraseLocalData`) suppresses further writes and abandons in-memory inline/recovery UI. A retiring view cannot recreate intentionally erased data.

## Trash integration

Knowledge's existing delete path now calls the root's `trashNote` API and says Move to Trash. Library actions exposes guarded Recently deleted notes via `NoteTrashSheet`; restore reloads actual notes and selects the restored exact URL. Drafts for a trashed original remain separately recoverable. No permanent purge UI was added.

## Tests and verification

`KnowledgeDraftRecoveryTests` has eight isolated temp-directory cases:

1. Restart retains final committed Unicode text and exact same-title/different-folder note identity while saved notes stay untouched; private file permissions and out-of-tree storage are checked.
2. A changed original cannot be adopted; saving a recovered copy preserves both versions.
3. Missing original recovers to a new identity without recreating its old path.
4. Invalid save/oversized checkpoint preserves the previous safe draft and original.
5. Reverting to original and explicit discard clear only the exact draft.
6. Corrupt checkpoint preserves valid siblings and its original bytes.
7. Recovery-directory symlink fails closed without writing private text through it.
8. A different vault cannot receive another vault's recovery record.

Parser and scoped whitespace checks pass. Parent owns integrated compilation/tests and live quit/relaunch UI qualification. No test uses the primary vault. No RelayApp termination hooks were required: committed edits survive normal close/quit, and recovery covers the last atomically committed state if the process dies during a write. This does not promise recovery of text that never reached its SwiftUI binding or storage when a reported write failure occurred.

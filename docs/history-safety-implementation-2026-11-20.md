# Conversation identity and recoverable history — 20 November 2026

## Problem and change

The prior audit identified a routine-restart duplication path: selecting archived A did not make the active SQLite journal belong to A. Appending a request stored only the new journal segment. Restart then split journal text by 15-minute gaps and matched only the first archived message, creating another thread for that segment.

The implementation now records explicit **journal run ID → workspace thread ID** ownership before staging new visible journal messages. It also persists the selected thread independently. This metadata lives in `workspace_threads.recovery.json`, beside the existing `workspace_threads.json` array; the existing archive format is unchanged. It contains identity/recovery data, not dispatch or approval authority.

On restart, journal records expose their immutable run IDs. Records merge into their owner by stable message IDs, preserving the canonical archive's earlier messages and their order. Existing IDs are not rewritten from older journal text. A long pause does not split an explicitly owned thread. The selected conversation need not be the conversation owning the most recent journal. No model call, tool replay, saved-user receipt, or executable continuation is produced by restoration.

Legacy metadata-free journals can adopt an archived conversation only when their actual message IDs establish one unambiguous owner. Ambiguous records already present in archives stay untouched. Genuinely new unmatched records are preserved separately. Time, titles, similar prose, and recency do not choose owners. Existing duplicated archives are not automatically merged or deleted. Loading no longer drops distinct thread IDs merely because they share a first-message ID. Explicit existing thread identity wins over legacy first-message adoption.

A malformed or newer recovery sidecar remains untouched and blocks new ownership binding. Archive writes retain their errors rather than clearing an unsaved flag before success. Ordinary thread selection is fenced while an actual conversation run is still settling final journal writes/native drain.

## Recovery instead of deletion

- `AssistantStore.deleteThread` moves the complete saved snapshot into persistent Trash before removing it from active history.
- `AssistantStore.clearThreadHistory` moves all active snapshots to Trash. Its UI must describe that recoverable behavior.
- `store.threadArchive.trashedThreads` exposes recoverable snapshots; `store.restoreThread(id)` restores exact identity/content without selecting it or executing history.
- Restore writes canonical archive bytes before removing the recovery tombstone. If metadata fails, the old tombstone still prevents resurrection and the snapshot stays recoverable.
- Journal restoration respects deleted-thread tombstones. Explicit internal `archive.clearAll()` remains destructive, retaining retired identities to prevent journal resurrection. The already-authorized factory-reset path separately clears the journal, then resets canonical archive/recovery metadata and the in-memory corruption latch. Failed writes remain visible; an unreadable sidecar cannot permanently block a successful reset until relaunch.
- The existing 60-active-thread cap now moves overflow snapshots to Trash rather than silently dropping them; if recovery persistence fails, it keeps those snapshots in the active array.

No permanent purge UI is added, and no user history was deleted, merged, or migrated by the agent's tools.

## Verification

New isolated `WorkspaceThreadRecoveryTests` use temporary state paths and inert visible-message staging; no provider, file/app tool, or primary user state is used. Cases cover two restart cycles after archived-thread append, a >15-minute gap, selected-thread/journal-owner separation, similar text with distinct stable identities, legacy interior-message adoption, persistent Trash/no-resurrection/exact restoration, corruption preserving original bytes, ambiguous shared-ID archives preserving both branches, and explicit factory reset unblocking new ownership without relaunch.

Parser and scoped whitespace checks passed. Root owns the integrated compile and fixture execution. This lane did not run a baseline build before editing; the failing path was established by source plus prior live observations, and the new isolated regressions still require execution before claiming runtime qualification.

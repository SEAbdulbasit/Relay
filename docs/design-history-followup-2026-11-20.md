# History follow-up discovered during design verification — 20 November 2026

**Implementation update:** the history ownership repair, inline-note draft recovery, recoverable Trash, and saved-result workflow are now implemented and qualified. See [current results and remaining boundaries](workflow-safety-2026-11-20.md). The audit below records the findings that led to this work.

Priority: **P1 — thread identity and restart reconciliation**. This is a source-supported duplication risk discovered during live design verification, separate from the presentation changes. No engine/history code or user records were changed by this read-only audit.

## Observed symptom

The coordinating agent reported selecting the existing synthetic reliability thread `3D76F9D1…`, whose preview previously contained the 12 × 13 explanation, and sending a new synthetic “Design status check” request for 7 × 8. After relaunch, a new `070808C9…` thread contained the new request/result, while the older thread's preview also showed `7 × 8 = 56`.

The older preview changing is consistent with appending a request to that selected thread. It is **not evidence that its earlier messages were lost**. The observed concern is that a request appended to an existing thread appears again as a separate restored thread. The exact complete stored transcripts were not inspected in this audit, so no data-loss or overwrite claim is made.

## Concrete source evidence

- `AssistantStore.swift:9–15` snapshots the current visible messages whenever messages change. `syncActiveThreadSnapshot` (`:5617`) upserts using the current `activeThreadID`. Therefore a new answer appended after selecting an old thread updates that thread and its preview.
- `selectThread` (`AssistantStore.swift:5718–5755`) installs the archive thread's ID, visible messages, activity and reconstructed model history. It does not activate a corresponding journal or establish a persisted journal-to-thread identity.
- `startNewThread` calls `clearConversation` (`AssistantStore.swift:5697–5714`). The latter resets the shared active journal (`:4467`); `AssistantConversationHistory.clear` (`:952–974`) creates a new journal scope/generation and clears its current records.
- Journal `stage` appends only the new visible event (`AssistantConversationHistory.swift:547–561`). Selecting an archived thread does not import its old visible messages into this active journal. `restore` (`:423`) reconstructs the active journal's current records, not the selected archive's full transcript.
- `AssistantStore.activeThreadID` is initialized to a new UUID (`:27`). The archive's `activeThreadID` also starts as a new UUID (`:5950`); `WorkspaceThreadArchive.load` (`:6102`) decodes an array of threads, not a persisted selected-thread binding.
- Startup restoration (`AssistantStore.swift:4725–4743`) replaces visible messages with restored journal messages, then invokes `seedHistoricalSessionsIfNeeded` with the startup ID.
- That seeding helper (`AssistantStore.swift:6033–6070`) selects the final time-based session segment even when the archive already contains multiple threads. Session splitting uses a 15-minute gap (`:6158–6178`).
- `WorkspaceThreadArchive.upsertThread` only adopts another archive thread when the **first** restored message ID equals that archive thread's **first** message ID (`AssistantStore.swift:5977–5982`). A journal containing the new request/result, or a final segment beginning with that request, cannot adopt an older thread whose first message is the original reliability prompt. It can consequently create the second thread observed after relaunch.

Line numbers refer to the source as audited; subsequent changes may shift them.

## Reproduction to qualify in an isolated fixture

1. Create a store and archive in a temporary directory. Enable the same startup archive reconciliation policy as the primary store through an explicit test seam; never point a test at the user's primary state path.
2. Complete thread A with at least one user/assistant pair, preserving its message IDs.
3. Start a blank thread B and let journal reset settle.
4. Select archived A, submit one new request, and finish its response. Verify A now contains both its old and new message IDs.
5. Flush persistence, release the store, and open a new store at the same temporary location.
6. Verify exactly one A exists, it preserves all expected message IDs in order, its selected identity is unchanged, and the new request/result do not appear as a separate duplicate thread.
7. Reopen once more to verify idempotence. Also cover a >15-minute gap within A using injected dates; that gap must not create a second thread during routine restart reconciliation.

The source is sufficient to identify this path, but this audit did not run the reproduction. Tests should establish the failure before implementing a repair.

## Safest data contract

Use an explicit persisted workspace-thread identity for journal ownership and startup selection. A journal generation/run needs an unambiguous owning thread; selecting a saved thread must restore or bind that thread's journal context without treating old stored text as a fresh user invocation. Startup should reconcile by stable IDs with that known owner, preserving the canonical archive's earlier messages and appending genuinely new saved records once.

Treat time-gap splitting as a one-time legacy import heuristic, not an ongoing source of thread identity during every launch. Do not merge, delete or reassign existing threads by message text, preview or timestamps. Avoid a narrow patch that merely chooses the latest archive thread: that can attach restored records to the wrong conversation.

Any migration should preserve existing archive/journal bytes and resolve ambiguous owners conservatively. Archived prose and journal records remain history data; the repair must not mint new dispatch authority, revive completed tasks, replay actions, or manufacture saved-user receipts by re-staging old messages.

## Acceptance cases

- Existing thread → new message → restart retains one stable thread and all prior messages.
- Blank thread → select another thread → send → restart retains the selected thread's identity.
- Long idle gap within a thread does not split it during ordinary restart.
- Repeated restart is idempotent.
- Two genuinely distinct threads with similar text remain distinct.
- Late callbacks and pending persistence cannot write a previous task into the newly selected thread.
- History restoration remains non-executable and never resends messages or tools.

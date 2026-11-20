import Foundation
import Testing
@testable import Relay

@Suite("Workspace restart identity and recoverable history")
@MainActor
struct WorkspaceThreadRecoveryTests {
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-thread-recovery-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("state.json")
    }

    @Test func selectedArchivedThreadAppendSurvivesTwoRestartsWithoutDuplicationOrReplay() async throws {
        let state = try location()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let a = ChatMessage(role: "user", text: "First request", date: .init(timeIntervalSince1970: 100))
        let b = ChatMessage(role: "assistant", text: "First result", date: .init(timeIntervalSince1970: 101))
        // A >15-minute pause is still one explicitly owned conversation.
        let c = ChatMessage(role: "user", text: "Second request", date: .init(timeIntervalSince1970: 10000))
        let d = ChatMessage(role: "assistant", text: "Second result", date: .init(timeIntervalSince1970: 10001))
        let history = AssistantConversationHistory(stateURL: state)
        let store = AssistantStore(persistenceURL: state, complete: { _, _, _ in
            Issue.record("Restoring or staging inert history must not invoke a provider")
            return ModelReply(content: "unexpected", toolCalls: [])
        }, conversationHistory: history)
        await store.waitForConversationTaskToSettle()
        try await store.stageVisibleConversationFixture([a, b], deferredUsers: [])
        let originalID = store.activeThreadID
        store.startNewThread()
        await store.waitForConversationTaskToSettle()
        #expect(store.selectThread(originalID))
        try await store.stageVisibleConversationFixture([c, d], deferredUsers: [])
        store.syncActiveThreadSnapshot(immediate: true)
        try await history.close()

        for _ in 0..<2 {
            let reopeningHistory = AssistantConversationHistory(stateURL: state)
            let reopening = AssistantStore(persistenceURL: state, complete: { _, _, _ in
                Issue.record("History restoration is never executable")
                return ModelReply(content: "unexpected", toolCalls: [])
            }, conversationHistory: reopeningHistory)
            await reopening.waitForConversationTaskToSettle()
            #expect(reopening.threadArchive.threads.count == 1)
            #expect(reopening.activeThreadID == originalID)
            #expect(reopening.messages.map(\.id) == [a.id, b.id, c.id, d.id])
            #expect(!reopening.canResumeCurrentTask)
            #expect(!reopening.isRunning)
            try await reopeningHistory.close()
        }
    }

    @Test func selectedThreadAndJournalOwnerAreIndependentOnRestart() async throws {
        let state = try location()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let history = AssistantConversationHistory(stateURL: state)
        let store = AssistantStore(persistenceURL: state, conversationHistory: history)
        await store.waitForConversationTaskToSettle()
        let first = ChatMessage(role: "user", text: "Same text")
        try await store.stageVisibleConversationFixture([first], deferredUsers: [])
        let firstID = store.activeThreadID
        store.startNewThread(); await store.waitForConversationTaskToSettle()
        let second = ChatMessage(role: "user", text: "Same text")
        try await store.stageVisibleConversationFixture([second], deferredUsers: [])
        let secondID = store.activeThreadID
        #expect(store.selectThread(firstID))
        try await history.close()
        let reloadedHistory = AssistantConversationHistory(stateURL: state)
        let reloaded = AssistantStore(persistenceURL: state, conversationHistory: reloadedHistory)
        await reloaded.waitForConversationTaskToSettle()
        #expect(reloaded.activeThreadID == firstID)
        #expect(reloaded.messages.map(\.id) == [first.id])
        #expect(reloaded.threadArchive.thread(for: secondID)?.messages.map(\.id) == [second.id])
        #expect(reloaded.threadArchive.threads.count == 2)
        try await reloadedHistory.close()
    }

    @Test func legacyInteriorMessageIDAdoptsOnlyAnUnambiguousCanonicalOwner() throws {
        let state = try location()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let archiveURL = state.deletingLastPathComponent().appendingPathComponent("workspace_threads.json")
        let a = ChatMessage(role: "user", text: "Older request")
        let b = ChatMessage(role: "assistant", text: "Older result")
        let c = ChatMessage(role: "user", text: "Newer request")
        let owner = UUID(), run = UUID()
        let archive = WorkspaceThreadArchive(storageURL: archiveURL)
        _ = archive.upsertThread(id: owner, messages: [a, b, c])
        let selected = try archive.reconcileJournal(messages: [c], activity: [], messageRunIDs: [c.id: run], selectedID: UUID())
        #expect(selected?.id == owner)
        #expect(selected?.messages.map(\.id) == [a.id, b.id, c.id])
        #expect(archive.threads.count == 1)
    }

    @Test func trashSurvivesRestartDoesNotResurrectFromJournalAndRestoresExactIdentity() throws {
        let state = try location()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let url = state.deletingLastPathComponent().appendingPathComponent("workspace_threads.json")
        let id = UUID(), run = UUID(), message = ChatMessage(role: "user", text: "Recover this")
        let archive = WorkspaceThreadArchive(storageURL: url)
        _ = archive.upsertThread(id: id, messages: [message])
        try archive.bindJournalRun(run, to: id)
        #expect(archive.deleteThread(id: id))
        let reopened = WorkspaceThreadArchive(storageURL: url)
        #expect(reopened.threads.isEmpty)
        #expect(reopened.trashedThreads.map(\.id) == [id])
        #expect(try reopened.reconcileJournal(messages: [message], activity: [], messageRunIDs: [message.id: run], selectedID: id) == nil)
        #expect(reopened.threads.isEmpty)
        #expect(reopened.restoreThread(id: id))
        let restored = WorkspaceThreadArchive(storageURL: url)
        #expect(restored.trashedThreads.isEmpty)
        #expect(restored.thread(for: id)?.messages.map(\.id) == [message.id])
    }

    @Test func corruptRecoveryMetadataIsPreservedAndBlocksNewOwnership() throws {
        let state = try location()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let url = state.deletingLastPathComponent().appendingPathComponent("workspace_threads.json")
        let metadata = url.deletingPathExtension().appendingPathExtension("recovery.json")
        let bytes = Data("not valid metadata".utf8)
        try bytes.write(to: metadata)
        let archive = WorkspaceThreadArchive(storageURL: url)
        #expect(throws: (any Error).self) { try archive.bindJournalRun(UUID(), to: UUID()) }
        #expect(try Data(contentsOf: metadata) == bytes)
    }
    @Test func ambiguousLegacySharedIDsNeverMergeOrRemoveDistinctSavedThreads() throws {
        let state = try location()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let url = state.deletingLastPathComponent().appendingPathComponent("workspace_threads.json")
        let shared = ChatMessage(role: "user", text: "A shared historical prefix")
        let a = UUID(), b = UUID(), run = UUID()
        let archive = WorkspaceThreadArchive(storageURL: url)
        _ = archive.upsertThread(id: a, messages: [shared, ChatMessage(role: "assistant", text: "Branch A")], adoptMatchingFirstMessage: false)
        _ = archive.upsertThread(id: b, messages: [shared, ChatMessage(role: "assistant", text: "Branch B")], adoptMatchingFirstMessage: false)
        let reopened = WorkspaceThreadArchive(storageURL: url)
        let prior = reopened.threads
        _ = try reopened.reconcileJournal(messages: [shared], activity: [], messageRunIDs: [shared.id: run], selectedID: b)
        #expect(reopened.threads.count == 2)
        #expect(reopened.threads == prior)
        #expect(reopened.activeThreadID == b)
    }

    @Test func explicitFactoryResetUnblocksUnreadableMetadataWithoutRelaunch() throws {
        let state = try location()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let url = state.deletingLastPathComponent().appendingPathComponent("workspace_threads.json")
        let metadata = url.deletingPathExtension().appendingPathExtension("recovery.json")
        try Data("unsupported recovery file".utf8).write(to: metadata)
        let archive = WorkspaceThreadArchive(storageURL: url)
        #expect(throws: (any Error).self) { try archive.bindJournalRun(UUID(), to: UUID()) }
        #expect(archive.resetForFactoryReset())
        try archive.bindJournalRun(UUID(), to: archive.activeThreadID)
        let reopened = WorkspaceThreadArchive(storageURL: url)
        #expect(reopened.threads.isEmpty)
        #expect(reopened.trashedThreads.isEmpty)
        try reopened.bindJournalRun(UUID(), to: reopened.activeThreadID)
    }

    @Test func unreadableOwnershipBlocksSubmissionBeforeProviderOrToolAndPreservesDraft() async throws {
        let state = try location()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let metadata = state.deletingLastPathComponent().appendingPathComponent("workspace_threads.recovery.json")
        let original = Data("unreadable ownership".utf8)
        try original.write(to: metadata)
        var inferences = 0, dispatches = 0
        let store = AssistantStore(persistenceURL: state, complete: { _, _, _ in
            inferences += 1
            return ModelReply(content: "Unexpected", toolCalls: [])
        }, execute: { _ in
            dispatches += 1
            return ToolResult(summary: "Unexpected", evidence: "Inert fixture", verified: false)
        })
        await store.waitForConversationTaskToSettle()
        store.draft = "Keep this draft when recovery metadata is unreadable."
        #expect(store.send() == nil)
        await store.waitForConversationTaskToSettle()
        #expect(inferences == 0 && dispatches == 0)
        #expect(store.draft == "Keep this draft when recovery metadata is unreadable.")
        #expect(store.errorMessage != nil)
        #expect(try Data(contentsOf: metadata) == original)
    }

}

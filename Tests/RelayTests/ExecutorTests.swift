import Foundation
import Testing
import RelayJournal
@testable import Relay

@MainActor
struct ExecutorTests {
    @Test func interruptedByteDistinctCallsKeepSeparateSettledAndUnconfirmedReceipts() async throws {
        let first = ToolCall(id: "caf\u{e9}", name: "calculate", arguments: ["expression": .string("1+1")])
        let second = ToolCall(id: "cafe\u{301}", name: "calculate", arguments: ["expression": .string("2+2")])
        var turn = 0, dispatches = 0
        var release: CheckedContinuation<Void, Never>?
        var resumedInput: [ModelMessage] = []
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turn += 1
            if turn == 1 { return ModelReply(content: "", toolCalls: [first, second]) }
            resumedInput = input
            return ModelReply(content: "Only the first result settled. The second request remains unconfirmed.", toolCalls: [])
        }, execute: { _ in
            dispatches += 1
            await withCheckedContinuation { release = $0 }
            return ToolResult(summary: "First result settled", evidence: "Synthetic result only", verified: true)
        })
        store.draft = "Calculate both synthetic expressions once."
        store.send()
        for _ in 0..<500 where release == nil { await Task.yield() }
        let pending = try #require(release)
        store.stop()
        store.resume()
        pending.resume()
        for _ in 0..<1000 where resumedInput.isEmpty || store.isRunning { await Task.yield() }
        #expect(dispatches == 1)
        #expect(!resumedInput.isEmpty && ContextWindow.isWellFormed(resumedInput))
        let settled = resumedInput.filter { $0.role == "tool" && $0.toolCallID?.utf8.elementsEqual(first.id.utf8) == true }
        let interrupted = resumedInput.filter { $0.role == "tool" && $0.toolCallID?.utf8.elementsEqual(second.id.utf8) == true }
        #expect(settled.count == 1 && settled[0].content.contains("First result settled"))
        #expect(interrupted.count == 1 && interrupted[0].content.contains("Interrupted; not confirmed executed"))
    }

    @Test func customStorePersistenceIsolatesAllSourceAndStyleState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDirectory = root.appendingPathComponent("first")
        let secondDirectory = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        let source = firstDirectory.appendingPathComponent("source.txt")
        try Data("Unique local source".utf8).write(to: source)
        let first = AssistantStore(persistenceURL: firstDirectory.appendingPathComponent("state.json"))
        first.grants = [ScopeGrant(path: source.path, writable: false)]
        await first.knowledge.index(grants: first.grants)
        first.writingProfile.preferredTone = "Unique approved tone"
        try first.writingProfile.save()
        let preferenceBefore = UserDefaults.standard.object(forKey: "relay.quickAccess.selection") as? Bool
        first.selectionCaptureEnabled.toggle()
        #expect((UserDefaults.standard.object(forKey: "relay.quickAccess.selection") as? Bool) == preferenceBefore)
        let second = AssistantStore(persistenceURL: secondDirectory.appendingPathComponent("state.json"))
        #expect(second.knowledge.records.isEmpty)
        #expect(!second.writingProfile.contextDescription().contains("Unique approved tone"))
        #expect(first.knowledge.records.count == 1)
        #expect(FileManager.default.fileExists(atPath: firstDirectory.appendingPathComponent("knowledge.json").path))
        #expect(FileManager.default.fileExists(atPath: firstDirectory.appendingPathComponent("writing-profile.json").path))
    }
    @Test func inferenceFailureKeepsCheckedPartialOutcomesVisible() async throws {
        var turn = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turn += 1
            if turn == 1 { return ModelReply(content: "", toolCalls: [ToolCall(name: "list_apps", arguments: [:])]) }
            throw RelayError.message("Summary interrupted")
        }, execute: { _ in ToolResult(summary: "Verified marker: fixture-only", evidence: "Synthetic partial-outcome oracle", verified: true) })
        store.draft = "Inspect a fixture"
        store.send()
        for _ in 0..<100 where store.isRunning { await Task.yield() }
        #expect(store.phase == .failed)
        #expect(store.messages.last?.text.contains("Verified marker: fixture-only") == true)
        #expect(store.messages.last?.text.contains("does not certify the whole task") == true)
        #expect(store.messages.last?.text.contains("Summary interrupted") == true)
    }
    @Test func forgettingCalendarExcludesPriorDerivedContextFromNextInference() async throws {
        var turn = 0
        var secondInput = ""
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turn += 1
            if turn == 1 { return ModelReply(content: "Synthetic private calendar context", toolCalls: []) }
            secondInput = input.map(\.content).joined(separator: "\n")
            return ModelReply(content: "New request", toolCalls: [])
        })
        store.draft = "First request"
        store.send()
        for _ in 0..<100 where store.isRunning { await Task.yield() }
        store.calendarSource.clear()
        store.draft = "A fresh request"
        store.send()
        for _ in 0..<100 where store.isRunning { await Task.yield() }
        #expect(!secondInput.contains("Synthetic private calendar context"))
        #expect(secondInput.contains("A fresh request"))
        #expect(store.messages.contains { $0.text.contains("Synthetic private calendar context") })
    }
    @Test func invalidSavedHistoryIsPreservedUntilExplicitReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("state.json"), broken = Data("{incomplete history".utf8)
        try broken.write(to: url)
        let history = AssistantConversationHistory(stateURL: url)
        let store = AssistantStore(persistenceURL: url, complete: { _, _, _ in .init(content: "Temporary answer", toolCalls: []) }, conversationHistory: history)
        #expect(store.errorMessage?.contains("preserved") == true)
        store.draft = "Temporary request"; store.send(); await store.waitForConversationTaskToSettle()
        #expect(try Data(contentsOf: url) == broken)
        store.clearConversation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isClearingConversation, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!store.isClearingConversation)
        // Explicit reset starts a new journal while preserving the unreadable legacy original.
        #expect(try Data(contentsOf: url) == broken)
        #expect(store.draft == "Temporary request")
        try await history.close()
        let restored = AssistantStore(persistenceURL: url)
        await restored.waitForConversationTaskToSettle()
        #expect(restored.messages.isEmpty)
    }
    @Test func clearingWaitsForOldCompletionBlocksSendAndResumeAndPreservesNewDraft() async throws {
        var release: CheckedContinuation<Void, Never>?
        var turns = 0
        var nextInput = ""
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return ModelReply(content: "", toolCalls: [ToolCall(name: "list_apps", arguments: [:])]) }
            nextInput = input.map(\.content).joined(separator: "\n")
            return ModelReply(content: "Fresh answer", toolCalls: [])
        }, execute: { _ in
            await withCheckedContinuation { release = $0 }
            return ToolResult(summary: "OLD_LATE_COMPLETION", evidence: "Synthetic old result", verified: true)
        })
        store.draft = "OLD_RESET_REQUEST"
        store.send()
        for _ in 0..<200 where release == nil { await Task.yield() }
        #expect(release != nil)
        store.clearConversation()
        #expect(store.isClearingConversation)
        store.draft = "New draft typed during reset"
        store.send()
        store.resume()
        store.stop() // Stopping again must not invalidate or strand the reset.
        store.clearConversation() // Duplicate reset requests must not create another reset.
        #expect(store.isClearingConversation)
        #expect(store.draft == "New draft typed during reset")
        #expect(turns == 1)
        #expect(!store.messages.contains { $0.role == "user" && $0.text == "New draft typed during reset" })
        release?.resume()
        for _ in 0..<300 where store.isClearingConversation { await Task.yield() }
        #expect(!store.isClearingConversation)
        #expect(!store.isRunning)
        #expect(store.messages.isEmpty)
        #expect(store.activity.isEmpty)
        #expect(store.draft == "New draft typed during reset")
        store.send()
        for _ in 0..<200 where store.isRunning { await Task.yield() }
        #expect(turns == 2)
        #expect(nextInput.contains("New draft typed during reset"))
        #expect(!nextInput.contains("OLD_LATE_COMPLETION"))
        #expect(!nextInput.contains("OLD_RESET_REQUEST"))
        #expect(store.messages.first?.text == "New draft typed during reset")
    }

    @Test func oversizedSparseHistoryIsRejectedBeforeAllocationAndNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("state.json")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(AssistantStore.maximumStateBytes + 1)); try handle.close()
        let store = AssistantStore(persistenceURL: url)
        #expect(store.errorMessage?.contains("preserved") == true)
        store.saveConfiguration()
        #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == AssistantStore.maximumStateBytes + 1)
    }
    @Test func stopBlocksRemainingBatchedDispatch() async throws {
        var dispatched = 0
        var store: AssistantStore!
        store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            ModelReply(content: "", toolCalls: [
                ToolCall(name: "list_apps", arguments: [:]),
                ToolCall(name: "list_apps", arguments: [:])
            ])
        }, execute: { _ in
            dispatched += 1
            store.stop()
            return ToolResult(summary: "First observation", evidence: "Test oracle", verified: true)
        })
        store.draft = "Inspect applications"
        store.send()
        for _ in 0..<100 where dispatched == 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        #expect(dispatched == 1)
        #expect(store.phase == .stopped)
        #expect(store.pendingReview == nil)
    }

    @Test func modelNarrativeCannotInventVerifiedAction() async throws {
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            ModelReply(content: "I opened the player.", toolCalls: [])
        })
        store.draft = "Open player"
        store.send()
        for _ in 0..<100 where store.isRunning { await Task.yield() }
        #expect(store.phase != .completed)
        #expect(store.messages.last?.text.contains("No computer actions were executed") == true)
        #expect(!store.activity.contains { $0.status == "verified" })
    }

    @Test func failedToolDoesNotBecomeSuccessfulTask() async throws {
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            return turns == 1 ? ModelReply(content: "", toolCalls: [ToolCall(name: "list_apps", arguments: [:])]) : ModelReply(content: "Done", toolCalls: [])
        }, execute: { _ in throw RelayError.message("Observation failed") })
        store.draft = "Inspect apps"
        store.send()
        for _ in 0..<100 where store.isRunning { await Task.yield() }
        #expect(store.phase == .needsInput)
        #expect(store.messages.last?.text.contains("No action outcome was independently verified") == true)
    }

    @Test func persistedInterruptionDoesNotReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL: state)
        let core = try await history.journalForTesting(), scope = try await core.scope(), task = UUID(), attempt = UUID()
        _ = try await core.acceptRequest(id: JournalOpaqueID(UUID().uuidString), taskID: task, attemptID: attempt,
            text: JournalVisibleText("Prepare document", origin: .user), expectedScope: scope)
        let intent = try JournalIntent(proposalID: UUID(), producerEpoch: core.producerEpoch, toolCallID: JournalOpaqueID("unfinished"),
            toolName: "open_app", callDigest: Data(repeating: 1, count: 32), effect: .mutation)
        _ = try await core.commitIntent(JournalEvent(id: JournalOpaqueID("unfinished-intent"), taskID: task, attemptID: attempt, payload: .intent(intent)), expectedScope: scope)
        // End the old writer with unfinished durable work; separate child-process tests cover abrupt WAL exit.
        try await history.close()
        var inferences = 0, dispatches = 0
        let restored = AssistantStore(persistenceURL: state, complete: { _, _, _ in inferences += 1; return ModelReply(content: "Unexpected", toolCalls: []) },
            execute: { _ in dispatches += 1; return ToolResult(summary: "Unexpected", evidence: "None", verified: false) })
        await restored.waitForConversationTaskToSettle()
        #expect(restored.phase == .stopped); #expect(!restored.isRunning)
        #expect(inferences == 0); #expect(dispatches == 0)
        #expect(restored.activity.allSatisfy { $0.status != "verified" && $0.status != "verified receipt" })
    }
    @Test func malformedModelCallsAreRetriedWithoutDispatchAndBounded() async throws {
        var attempts = 0
        var dispatches = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            attempts += 1
            throw ModelProtocolError.invalidAction("wrong argument type")
        }, execute: { _ in
            dispatches += 1
            return ToolResult(summary: "Unexpected", evidence: "Must not run", verified: false)
        })
        store.draft = "Prepare an output"
        store.send()
        for _ in 0..<150 where store.isRunning { await Task.yield() }
        #expect(attempts == 3)
        #expect(dispatches == 0)
        #expect(store.phase == .failed)
        #expect(store.activity.filter { $0.name == "Correcting action request" }.count == 2)
    }

    @Test func validObservationStillDoesNotCertifyWholeUserGoal() async throws {
        var turn = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turn += 1
            if turn == 1 { return ModelReply(content: "", toolCalls: [ToolCall(name: "list_apps", arguments: [:])]) }
            return ModelReply(content: "All done", toolCalls: [])
        }, execute: { _ in ToolResult(summary: "Listed apps", evidence: "Observation only", verified: true) })
        store.draft = "Fill the form"
        store.send()
        for _ in 0..<150 where store.isRunning { await Task.yield() }
        #expect(store.phase != .completed)
        #expect(store.messages.last?.text.contains("Listed apps") == true)
    }

    @Test func revocationExcludesLatePrivateResultButPreservesNewUserRequest() async throws {
        var turn = 0
        var release: CheckedContinuation<Void, Never>?
        var nextInput: [ModelMessage] = []
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turn += 1
            if turn == 1 {
                return ModelReply(content: "", toolCalls: [ToolCall(name: "read_file", arguments: ["path": .string("/private/source.txt")])])
            }
            nextInput = input
            return ModelReply(content: "Public answer", toolCalls: [])
        }, execute: { _ in
            await withCheckedContinuation { release = $0 }
            return ToolResult(summary: "PRIVATE_LATE_SOURCE", evidence: "Private excerpt", verified: true)
        })
        let grant = ScopeGrant(path: "/private/source.txt", writable: false)
        store.grants = [grant]
        store.draft = "Read PRIVATE_OLD_OBJECTIVE"
        store.send()
        for _ in 0..<150 where release == nil { await Task.yield() }
        #expect(release != nil)
        store.removeGrant(grant.id)
        store.draft = "New public question"
        store.send()
        release?.resume()
        for _ in 0..<200 where store.isRunning { await Task.yield() }
        #expect(turn == 2)
        let context = nextInput.map(\.content).joined(separator: "\n")
        #expect(context.contains("New public question"))
        #expect(!context.contains("PRIVATE_LATE_SOURCE"))
        #expect(!context.contains("PRIVATE_OLD_OBJECTIVE"))
        #expect(ContextWindow.isWellFormed(nextInput))
        #expect(store.messages.contains { $0.text.contains("PRIVATE_LATE_SOURCE") })
    }

    @Test func revokedInferenceContextStaysRevokedAfterRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json")
        let firstHistory = AssistantConversationHistory(stateURL: state)
        let first = AssistantStore(persistenceURL: state, complete: { _, _, _ in
            ModelReply(content: "PRIVATE_SAVED_ANSWER", toolCalls: [])
        }, conversationHistory: firstHistory)
        let grant = ScopeGrant(path: "/private/source.txt", writable: false)
        first.grants = [grant]
        first.draft = "PRIVATE_SAVED_REQUEST"
        first.send()
        await first.waitForConversationTaskToSettle()
        first.removeGrant(grant.id)
        try await firstHistory.close()
        var restoredInput: [ModelMessage] = []
        let restored = AssistantStore(persistenceURL: state, complete: { input, _, _ in
            restoredInput = input
            return ModelReply(content: "New answer", toolCalls: [])
        })
        restored.draft = "New question after relaunch"
        restored.send()
        await restored.waitForConversationTaskToSettle()
        let context = restoredInput.map(\.content).joined(separator: "\n")
        #expect(!restoredInput.isEmpty)
        #expect(!context.contains("PRIVATE_SAVED"))
        #expect(context.contains("New question after relaunch"))
        #expect(restored.messages.contains { $0.text.contains("PRIVATE_SAVED_ANSWER") })
    }

}

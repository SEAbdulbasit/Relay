import Foundation
import RelayJournal
import Testing
@testable import Relay

/// Scripted providers and inert dispatch closures exercise the production Store
/// and journal. These fixtures never open applications or contact providers.
@MainActor
struct TaskContinuationAuthorityTests {
    @Test(arguments: [false, true])
    func explicitDeclineRequiresANewInstructionBeforeAnotherRun(multiAgent: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-decline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned.txt")
        let original = Data("ORIGINAL_OWNED_BYTES".utf8)
        try original.write(to: file)
        var inferences = 0, dispatches = 0, newRequest = false
        let call = ToolCall(id: "declined-write", name: "write_file", arguments: [
            "path": .string(file.path), "content": .string("MUST_NOT_BE_WRITTEN")
        ])
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            inferences += 1
            if newRequest { return .init(content: "Here is a new informational response.", toolCalls: []) }
            if multiAgent, input.first?.content.contains("ROLE: Planner") == true {
                return .init(content: #"{"steps":[{"id":"owned","role":"Executor","title":"Replace the selected owned fixture"}]}"#, toolCalls: [])
            }
            return .init(content: "", toolCalls: [call])
        }, execute: { _ in
            dispatches += 1
            return .init(summary: "Unexpected dispatch", evidence: "Inert fixture", verified: false)
        }, multiAgent: multiAgent)
        defer { store.stop() }
        store.setAutoApproveRoutineActions(false)
        store.grants = [.init(path: root.path, writable: true)]
        store.draft = "Replace the selected owned fixture with the reviewed text."
        store.send()
        try await until { store.pendingReview != nil }
        #expect(store.phase == .awaitingReview && dispatches == 0)
        store.denyReview()
        await store.waitForConversationTaskToSettle()
        #expect(store.phase == .needsInput && !store.canResumeCurrentTask)
        let priorInferences = inferences
        store.resume()
        store.resume()
        await store.waitForConversationTaskToSettle()
        #expect(inferences == priorInferences && dispatches == 0 && store.pendingReview == nil)
        #expect(store.errorMessage?.contains("declined") == true)
        #expect(try Data(contentsOf: file) == original)

        // A new explicit instruction creates a fresh logical task, rather than
        // silently treating Continue as permission to reoffer the denied action.
        newRequest = true
        store.draft = "Explain how to organize a note without modifying any files."
        store.send()
        await store.waitForConversationTaskToSettle()
        #expect(inferences == priorInferences + 1 && dispatches == 0)
        #expect(store.phase == .idle && !store.canResumeCurrentTask)
        #expect(store.messages.last?.text.contains("new informational response") == true)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func successfulResponseCannotBeReexecutedByRepeatedContinue() async throws {
        var inferences = 0, dispatches = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            inferences += 1
            return inferences == 1
                ? .init(content: "", toolCalls: [.init(id: "once", name: "calculate", arguments: ["expression": .string("2+2")])])
                : .init(content: "The fixture result is four.", toolCalls: [])
        }, execute: { _ in
            dispatches += 1
            return .init(summary: "4", evidence: "Owned arithmetic fixture", verified: true)
        })
        defer { store.stop() }
        store.draft = "Calculate 2+2."
        store.send()
        await store.waitForConversationTaskToSettle()
        #expect(store.phase == .idle && inferences == 2 && dispatches == 1)
        #expect(!store.canResumeCurrentTask)
        store.resume(); store.resume()
        await store.waitForConversationTaskToSettle()
        #expect(inferences == 2 && dispatches == 1 && store.phase == .idle)
    }

    @Test func rapidStopAndContinueWaitsForAnInFlightEffectBeforePlanningAgain() async throws {
        var inferences = 0, dispatches: [String] = [], resumed: [ModelMessage] = []
        var release: CheckedContinuation<Void, Never>?
        let first = ToolCall(id: "first-owned-effect", name: "open_app", arguments: ["app": .string("test.inert.only")])
        let unstarted = ToolCall(id: "never-dispatched", name: "list_apps", arguments: [:])
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            inferences += 1
            if inferences == 1 { return .init(content: "", toolCalls: [first, unstarted]) }
            resumed = input
            return .init(content: "The earlier inert effect settled. No action was repeated.", toolCalls: [])
        }, execute: { call in
            dispatches.append(call.id)
            await withCheckedContinuation { release = $0 }
            return .init(summary: "OWNED_LATE_RESULT", evidence: "One inert effect settled after Stop", verified: true)
        })
        defer { store.stop(); release?.resume(); release = nil }
        store.draft = "Perform the two inert fixture operations once."
        store.send()
        try await until { release != nil }
        store.stop()
        #expect(store.phase == .stopped && store.canResumeCurrentTask)
        store.draft = "Keep this unsent café draft."
        store.resume()
        store.resume() // Already running: no extra continuation may be created.
        #expect(inferences == 1 && dispatches == [first.id])
        let pending = try #require(release)
        release = nil
        pending.resume()
        await store.waitForConversationTaskToSettle()
        #expect(inferences == 2 && dispatches == [first.id])
        #expect(ContextWindow.isWellFormed(resumed))
        #expect(resumed.contains { $0.role == "tool" && $0.toolCallID == first.id && $0.content.contains("OWNED_LATE_RESULT") })
        #expect(resumed.contains { $0.role == "tool" && $0.toolCallID == unstarted.id && $0.content.contains("Interrupted; not confirmed executed") })
        #expect(store.draft == "Keep this unsent café draft.")
        #expect(!store.isRunning && !store.canResumeCurrentTask)
    }

    @Test func restartAfterDeclineRestoresFactsWithoutAuthorityOrReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-decline-restart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned.txt")
        try Data("ORIGINAL".utf8).write(to: file)
        let state = root.appendingPathComponent("state.json")
        let history = AssistantConversationHistory(stateURL: state)
        var dispatches = 0
        let first = AssistantStore(persistenceURL: state, complete: { _, _, _ in
            .init(content: "", toolCalls: [.init(name: "write_file", arguments: ["path": .string(file.path), "content": .string("REJECTED")])])
        }, conversationHistory: history, execute: { _ in
            dispatches += 1
            return .init(summary: "Unexpected", evidence: "Inert fixture", verified: false)
        })
        first.setAutoApproveRoutineActions(false)
        first.grants = [.init(path: root.path, writable: true)]
        first.draft = "Replace this owned file with the reviewed text."
        first.send()
        try await until { first.pendingReview != nil }
        first.denyReview()
        await first.waitForConversationTaskToSettle()
        try await history.close()

        var restoredInferences = 0
        let restoredHistory = AssistantConversationHistory(stateURL: state)
        let restored = AssistantStore(persistenceURL: state, complete: { _, _, _ in
            restoredInferences += 1
            return .init(content: "Unexpected", toolCalls: [])
        }, conversationHistory: restoredHistory, execute: { _ in
            dispatches += 1
            return .init(summary: "Unexpected", evidence: "Inert fixture", verified: false)
        })
        await restored.waitForConversationTaskToSettle()
        #expect(!restored.messages.isEmpty && restored.phase == .needsInput)
        #expect(!restored.canResumeCurrentTask && restored.pendingReview == nil)
        restored.resume()
        await restored.waitForConversationTaskToSettle()
        #expect(restoredInferences == 0 && dispatches == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "ORIGINAL")
        try await restoredHistory.close()
    }

    @Test func successfulRecoveryClearsTheEarlierInferenceErrorAndPreservesDraft() async throws {
        var inferences = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            inferences += 1
            if inferences == 1 { throw RelayError.message("OWNED_PROVIDER_FAILURE") }
            return .init(content: "The resumed informational answer is ready.", toolCalls: [])
        })
        defer { store.stop() }
        store.draft = "Explain how a fixture works."
        store.send()
        await store.waitForConversationTaskToSettle()
        #expect(store.phase == .failed && store.canResumeCurrentTask)
        #expect(store.errorMessage?.contains("OWNED_PROVIDER_FAILURE") == true)
        store.draft = "Keep this unsent next request."
        store.resume()
        await store.waitForConversationTaskToSettle()
        #expect(inferences == 2 && store.phase == .idle && !store.canResumeCurrentTask)
        #expect(store.errorMessage == nil)
        #expect(store.draft == "Keep this unsent next request.")
        #expect(store.messages.last?.text.contains("resumed informational answer") == true)
    }

    @Test(arguments: [false, true])
    func instructionAcceptedImmediatelyAfterDeclineOwnsFreshRecoverableTask(multiAgent: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-immediate-decline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned.txt")
        try Data("ORIGINAL".utf8).write(to: file)
        let history = AssistantConversationHistory(stateURL: nil)
        var replacement = false, replacementTurns = 0, dispatches = 0
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            if replacement {
                replacementTurns += 1
                if replacementTurns == 1 { throw RelayError.message("OWNED_NEW_REQUEST_FAILURE") }
                return .init(content: "The replacement informational task recovered.", toolCalls: [])
            }
            if multiAgent, input.first?.content.contains("ROLE: Planner") == true {
                return .init(content: #"{"steps":[{"id":"owned","role":"Executor","title":"Replace owned fixture"}]}"#, toolCalls: [])
            }
            return .init(content: "", toolCalls: [.init(name: "write_file", arguments: [
                "path": .string(file.path), "content": .string("DECLINED")
            ])])
        }, conversationHistory: history, execute: { _ in
            dispatches += 1
            return .init(summary: "Unexpected", evidence: "Inert fixture", verified: false)
        }, multiAgent: multiAgent)
        defer { store.stop() }
        store.setAutoApproveRoutineActions(false)
        store.grants = [.init(path: root.path, writable: true)]
        store.draft = "Replace the owned fixture."
        store.send()
        try await until { store.pendingReview != nil }
        store.denyReview()
        // No suspension: the denied run still appears awaitingReview here.
        #expect(store.phase == .awaitingReview)
        replacement = true
        store.draft = "Explain how to organize a note without modifying files."
        try #require(store.send() != nil)
        await store.waitForConversationTaskToSettle()
        #expect(store.phase == .failed && store.canResumeCurrentTask)
        #expect(store.errorMessage?.contains("OWNED_NEW_REQUEST_FAILURE") == true)
        store.resume()
        await store.waitForConversationTaskToSettle()
        #expect(replacementTurns == 2 && dispatches == 0 && store.phase == .idle)
        #expect(store.errorMessage == nil && store.pendingReview == nil)
        #expect(store.messages.last?.text.contains("replacement informational task recovered") == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == "ORIGINAL")

        let core = try await history.journalForTesting(), scope = try await core.scope()
        let page = try await core.page(expectedScope: scope)
        let relations = page.records.compactMap { record -> JournalRunRelation? in
            if case let .started(_, relation) = record.event.payload { return relation }
            return nil
        }
        let original = try #require(relations.first)
        let fresh = try #require(relations.dropFirst().first)
        let resumed = try #require(relations.dropFirst(2).first)
        #expect(relations.count == 3)
        #expect(fresh.cause == .newRequest && fresh.logicalTaskID != original.logicalTaskID)
        #expect(resumed.cause == .resume && resumed.logicalTaskID == fresh.logicalTaskID)
        try await history.close()
    }

    @Test(arguments: [false, true])
    func standaloneVoiceCancellationPreservesConversationCompletionAndRecovery(failedTask: Bool) async throws {
        let backend = RecoveryVoiceBackend()
        let voice = LocalVoiceInput(localeIdentifier: "en-US", backend: backend, sleepNotificationCenter: NotificationCenter())
        var inferences = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            inferences += 1
            if failedTask, inferences == 1 { throw RelayError.message("OWNED_RECOVERABLE_FAILURE") }
            return .init(content: "The informational task is ready.", toolCalls: [])
        }, voiceInput: voice)
        defer { voice.cancel(); store.stop() }
        store.draft = "Explain the fixture without taking actions."
        store.send()
        await store.waitForConversationTaskToSettle()
        let phase = store.phase, messageCount = store.messages.count, activityCount = store.activity.count
        #expect(phase == (failedTask ? .failed : .idle))
        #expect(store.canResumeCurrentTask == failedTask)
        await voice.start()
        #expect(voice.isRecording && backend.recording && !store.isRunning)
        store.stop()
        #expect(!voice.isBusy && !backend.recording)
        #expect(store.phase == phase && store.messages.count == messageCount && store.activity.count == activityCount)
        #expect(store.canResumeCurrentTask == failedTask)
        store.resume()
        await store.waitForConversationTaskToSettle()
        #expect(inferences == (failedTask ? 2 : 1))
        #expect(store.phase == .idle && !store.canResumeCurrentTask)
    }

    @Test func progressFromAStoppedRunCannotLeakIntoAReplacementRequest() async throws {
        var replacement = false, dispatches = 0
        var release: CheckedContinuation<Void, Never>?
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            if replacement { return .init(content: "The replacement requires no device work.", toolCalls: []) }
            if input.first?.content.contains("ROLE: Planner") == true {
                return .init(content: #"{"steps":[{"id":"same","role":"Executor","title":"Owned step"},{"id":"same","role":"Executor","title":"Owned step"}]}"#, toolCalls: [])
            }
            return .init(content: "", toolCalls: [.init(name: "open_app", arguments: ["app": .string("test.inert.progress")])])
        }, execute: { _ in
            dispatches += 1
            await withCheckedContinuation { release = $0 }
            return .init(summary: "Owned inert dispatch settled", evidence: "No desktop action", verified: true)
        }, multiAgent: true)
        defer { store.stop(); release?.resume(); release = nil }
        store.draft = "Perform the two owned inert steps."
        store.send()
        try await until { release != nil }
        #expect(store.currentPlanProgress.count == 2)
        #expect(Set(store.currentPlanProgress.map(\.id)).count == 2)
        #expect(store.currentPlanProgress.first?.state == .running)
        #expect(store.currentPlanProgress.last?.state == .planned)
        store.stop()
        #expect(store.currentPlanProgress.first?.state == .stopped)
        #expect(store.currentPlanProgress.last?.state == .planned)
        replacement = true
        store.draft = "Explain an inert fixture without device work."
        store.send(useMultiAgent: false)
        #expect(store.currentPlanProgress.isEmpty && store.currentPlanSteps.isEmpty)
        let pending = try #require(release)
        release = nil
        pending.resume()
        await store.waitForConversationTaskToSettle()
        #expect(dispatches == 1 && store.phase == .idle)
        #expect(store.currentPlanProgress.isEmpty && store.currentPlanSteps.isEmpty)
        #expect(store.messages.last?.text.contains("replacement requires no device work") == true)
    }

    private func until(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(predicate(), "The inert fixture did not reach its expected checkpoint")
    }
}

@MainActor
private final class RecoveryVoiceBackend: LocalVoiceBackend {
    var recording = false
    func capability(localeIdentifier: String) -> LocalVoiceCapability {
        .init(localeSupported: true, onDeviceSupported: true)
    }
    func requestPermissions() async throws {}
    func begin(localeIdentifier: String, requiresOnDeviceRecognition: Bool,
               onEvent: @escaping @MainActor @Sendable (LocalSpeechEvent) -> Void) throws {
        recording = true
    }
    func stop() { recording = false }
}

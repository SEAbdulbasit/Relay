import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@MainActor @Suite(.serialized) struct MultiAgentStepCheckpointStoreTests {
    @Test(arguments: [JournalFault.beforeCommit, .afterCommit])
    func realSQLiteRepairThenContinueReadsPendingStepWithoutAnotherPlannerOrExecutor(_ fault: JournalFault) async throws {
        let rig = try await Rig(fault: fault)
        defer { rig.removeOwnedFiles() }
        rig.store.draft = rig.goal; rig.store.send(); await rig.store.waitForConversationTaskToSettle()
        #expect(rig.store.phase == .failed && rig.writtenPaths == [rig.output.path])
        #expect(rig.planners == 1 && rig.executors == 1 && rig.reads == 0)
        try await rig.store.retryConversationStorage()
        #expect(rig.planners == 1 && rig.executors == 1 && rig.writtenPaths.count == 1 && rig.reads == 0)
        rig.resuming = true; rig.store.resume(); await rig.store.waitForConversationTaskToSettle()
        #expect(rig.store.phase == .idle && rig.planners == 1 && rig.executors == 1)
        #expect(rig.resumeRoles == ["critic-read", "critic-verdict", "synthesis"])
        #expect(rig.reads == 1 && rig.writtenPaths == [rig.output.path])
        #expect(try Data(contentsOf: rig.output) == rig.expected)
        let records = try await rig.records()
        let intents = records.compactMap { record -> JournalIntent? in if case let .intent(value) = record.event.payload { value } else { nil } }
        let results = records.filter { if case .result = $0.event.payload { true } else { false } }
        #expect(intents.count == 2 && results.count == 2)
        #expect(intents.filter { $0.toolName == "write_file" }.count == 1)
        #expect(intents.filter { $0.toolName == "read_file" }.count == 1)
        // The provider ID was deliberately reused by a new accepted read reply;
        // the original write intent/receipt was never regenerated.
        #expect(intents[0].proposalID != intents[1].proposalID)
        try await rig.history.close()
    }

    @Test func aReconciledStepContinuesOnlyTheOriginalUnstartedRemainder() async throws {
        let rig = try await Rig(fault: .beforeCommit)
        defer { rig.removeOwnedFiles() }
        rig.sequentialSteps = true
        rig.store.draft = rig.goal; rig.store.send(); await rig.store.waitForConversationTaskToSettle()
        #expect(rig.writtenPaths == [rig.output.path] && rig.executors == 1 && rig.planners == 1)
        try await rig.store.retryConversationStorage()
        rig.resuming = true; rig.store.resume(); await rig.store.waitForConversationTaskToSettle()
        #expect(rig.store.phase == .idle && rig.planners == 1 && rig.executors == 2)
        #expect(rig.writtenPaths == [rig.output.path, rig.second.path] && rig.reads == 2)
        #expect(rig.resumeRoles == ["critic-read", "critic-verdict", "executor", "critic-read", "critic-verdict", "synthesis"])
        #expect(try Data(contentsOf: rig.output) == rig.expected)
        #expect(try Data(contentsOf: rig.second) == Data("SECOND".utf8))
        let writes = try await rig.records().compactMap { record -> JournalIntent? in
            if case let .intent(value) = record.event.payload, value.toolName == "write_file" { value } else { nil }
        }
        #expect(writes.count == 2 && writes[0].proposalID != writes[1].proposalID)
        try await rig.history.close()
    }

    @Test(arguments: ["before-dispatch", "after-dispatch"])
    func actualStoreStopAndDrainKeepPendingExecutorReadOnly(_ boundary: String) async throws {
        let rig = try await Rig(fault: nil)
        defer { rig.releaseAll(); rig.removeOwnedFiles() }
        rig.pauseExecutorReply = boundary == "before-dispatch"
        rig.pauseWriteReturn = boundary == "after-dispatch"
        rig.store.draft = rig.goal; rig.store.send()
        try await rig.wait { boundary == "before-dispatch" ? rig.executorWaiting : rig.writeWaiting }
        rig.store.stop(); rig.resuming = true; rig.store.resume()
        #expect(rig.reads == 0 && rig.executors == 1)
        rig.releaseAll(); await rig.store.waitForConversationTaskToSettle()
        #expect(rig.planners == 1 && rig.executors == (boundary == "before-dispatch" ? 2 : 1) && rig.reads == 1)
        #expect(rig.resumeRoles.first == (boundary == "before-dispatch" ? "executor" : "critic-read"))
        #expect(rig.writtenPaths.count == 1 && rig.store.phase == .idle)
        #expect(try Data(contentsOf: rig.output) == rig.expected)
        let intents = try await rig.records().compactMap { record -> JournalIntent? in if case let .intent(value) = record.event.payload { value } else { nil } }
        #expect(intents.filter { $0.toolName == "write_file" }.count == 1)
        try await rig.history.close()
    }

    @Test func partialBatchStaysTruthfullyIncompleteWithoutReplayingItsMissingWriteOrFollowingStep() async throws {
        let rig = try await Rig(fault: .beforeCommit)
        defer { rig.removeOwnedFiles() }
        rig.partialBatch = true
        rig.store.draft = rig.goal; rig.store.send(); await rig.store.waitForConversationTaskToSettle()
        #expect(rig.writtenPaths == [rig.output.path] && rig.executors == 1)
        try await rig.store.retryConversationStorage()
        rig.resuming = true; rig.store.resume(); await rig.store.waitForConversationTaskToSettle()
        #expect(rig.store.phase == .needsInput && rig.planners == 1 && rig.executors == 1)
        #expect(rig.writtenPaths == [rig.output.path] && rig.reads == 2 && rig.verdicts == 0)
        #expect(!FileManager.default.fileExists(atPath: rig.second.path) && !FileManager.default.fileExists(atPath: rig.third.path))
        let writes = try await rig.records().filter { if case let .intent(value) = $0.event.payload { value.toolName == "write_file" } else { false } }
        #expect(writes.count == 1)
        try await rig.history.close()
    }

    @Test func changedFileIsFreshlyReadAndUnverifiedWithoutReusingOmittedPrivateReceipt() async throws {
        let rig = try await Rig(fault: .beforeCommit)
        defer { rig.removeOwnedFiles() }
        rig.store.draft = rig.goal; rig.store.send(); await rig.store.waitForConversationTaskToSettle()
        try await rig.store.retryConversationStorage()
        let changed = Data(String(repeating: "z", count: rig.expected.count).utf8)
        try changed.write(to: rig.output)
        rig.resuming = true; rig.store.resume(); await rig.store.waitForConversationTaskToSettle()
        #expect(rig.store.phase == .needsInput && rig.planners == 1 && rig.executors == 1 && rig.reads == 1)
        #expect(rig.lastRead == changed && rig.writtenPaths == [rig.output.path])
        #expect(!rig.firstResumedInput.contains(rig.receiptMarker))
        #expect(rig.firstResumedInput.contains("omitted_receipts"))
        #expect(try Data(contentsOf: rig.output) == changed)
        try await rig.history.close()
    }

    @Test(arguments: ["configuration", "grants"])
    func actualStoreChangedScopeRefusesCachedPlanBeforeAnotherModelCall(_ change: String) async throws {
        let rig = try await Rig(fault: .beforeCommit)
        defer { rig.removeOwnedFiles() }
        rig.store.draft = rig.goal; rig.store.send(); await rig.store.waitForConversationTaskToSettle()
        try await rig.store.retryConversationStorage()
        let originalInferences = rig.inferences
        if change == "configuration" { rig.store.configuration.modelPath = "/different/model.litertlm" }
        else { rig.store.grants = [] }
        rig.resuming = true; rig.store.resume(); await rig.store.waitForConversationTaskToSettle()
        #expect(rig.store.phase == .failed && rig.inferences == originalInferences)
        #expect(rig.writtenPaths == [rig.output.path] && rig.reads == 0)
        #expect(rig.store.errorMessage?.contains("Start a fresh task") == true)
        try await rig.history.close()
    }

    @Test func aNewAcknowledgedTaskDropsOnlySchedulingCacheAndDoesNotInheritOldPlan() async throws {
        let rig = try await Rig(fault: .beforeCommit)
        defer { rig.removeOwnedFiles() }
        rig.store.draft = rig.goal; rig.store.send(); await rig.store.waitForConversationTaskToSettle()
        try await rig.store.retryConversationStorage()
        rig.distinctTask = true
        rig.store.draft = "Answer a distinct synthetic question without computer actions."
        let submission = try #require(rig.store.send())
        await rig.store.waitForConversationTaskToSettle()
        #expect(submission.status == .saved)
        #expect(rig.planners == 2 && rig.executors == 1 && rig.reads == 0 && rig.store.phase == .idle)
        #expect(!rig.distinctTaskInput.contains(rig.receiptMarker))
        #expect(rig.writtenPaths == [rig.output.path])
        try await rig.history.close()
    }

    @Test func steeringCannotTurnTheOldPendingStepIntoAnotherExecutor() async throws {
        let rig = try await Rig(fault: nil)
        defer { rig.releaseAll(); rig.removeOwnedFiles() }
        rig.pauseWriteReturn = true
        rig.store.draft = rig.goal; rig.store.send()
        try await rig.wait { rig.writeWaiting }
        let before = rig.inferences
        rig.store.draft = "Change this task's goal; do not reuse its earlier action."
        _ = try #require(rig.store.send())
        rig.releaseAll(); await rig.store.waitForConversationTaskToSettle()
        #expect(rig.store.phase == .failed && rig.inferences == before)
        #expect(rig.writtenPaths == [rig.output.path] && rig.executors == 1 && rig.reads == 0)
        #expect(rig.store.errorMessage?.contains("task instruction changed") == true)
        let writes = try await rig.records().filter { if case let .intent(value) = $0.event.payload { value.toolName == "write_file" } else { false } }
        #expect(writes.count == 1)
        try await rig.history.close()
    }

    @MainActor private final class Rig {
        let root: URL, output: URL, second: URL, third: URL
        let history: AssistantConversationHistory
        let journal: ConversationJournal
        let fault: JournalFault?
        private let fileTools = MacTools()
        let expected = Data("OWNED_EXACT_cafe\u{301}_🌍\n".utf8)
        let receiptMarker = "OWNED_STEP_RECEIPT_ONLY_ONCE"
        var goal: String {
            if sequentialSteps { return "Create \(output.path) with the first exact owned bytes once, verify it, then create \(second.path) with SECOND and verify it. Do not repeat a settled earlier write." }
            if partialBatch { return "Create the complete owned output pair at \(output.path) and \(second.path) once, verify both, then create \(third.path). Do not repeat an earlier write." }
            return "Create exactly \(output.path) once with the requested owned bytes, then inspect its contents. Do not repeat a previous write."
        }
        var partialBatch = false, sequentialSteps = false, resuming = false, distinctTask = false
        var pauseExecutorReply = false, pauseWriteReturn = false, executorWaiting = false, writeWaiting = false
        var planners = 0, executors = 0, reads = 0, verdicts = 0, inferences = 0
        var writtenPaths: [String] = [], resumeRoles: [String] = [], firstResumedInput = "", distinctTaskInput = ""
        var lastRead = Data()
        private var executorContinuation: CheckedContinuation<Void, Never>?
        private var writeContinuation: CheckedContinuation<Void, Never>?

        init(fault: JournalFault?) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-step-continuity-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            output = root.appendingPathComponent("one.txt"); second = root.appendingPathComponent("two.txt"); third = root.appendingPathComponent("three.txt")
            history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json"))
            journal = try await history.journalForTesting()
            self.fault = fault
        }

        lazy var store: AssistantStore = {
            let value = AssistantStore(persistenceURL: nil, complete: { [weak self] input, tools, _ in
                guard let self else { throw CancellationError() }
                return try await self.reply(input, tools: tools)
            }, conversationHistory: history, continuationProofWorker: SelectedFileProofWorker(), execute: { [weak self] call in
                guard let self else { throw CancellationError() }
                return try await self.action(call)
            }, multiAgent: true)
            value.grants = [.init(path: root.path, writable: true)]
            return value
        }()

        func reply(_ input: [ModelMessage], tools: [ToolDefinition]) async throws -> ModelReply {
            inferences += 1
            let role = input.first?.content ?? "", payload = input.map(\.content).joined(separator: "\n")
            if resuming, firstResumedInput.isEmpty { firstResumedInput = payload }
            if role.contains("ROLE: Planner") {
                if input.last?.content.contains("Synthesize") == true {
                    if resuming { resumeRoles.append("synthesis") }
                    return .init(content: "The fresh owned read supports the checked outcome.", toolCalls: [])
                }
                planners += 1
                if distinctTask { distinctTaskInput = payload; return .init(content: "A distinct informational answer.", toolCalls: []) }
                if sequentialSteps { return .init(content: #"{"steps":[{"id":"same","role":"Executor","title":"Create the first owned output once"},{"id":"same","role":"Executor","title":"Create the second owned output once"}]}"#, toolCalls: []) }
                if partialBatch { return .init(content: #"{"steps":[{"id":"same","role":"Executor","title":"Create both owned outputs"},{"id":"same","role":"Executor","title":"Create the unstarted third output"}]}"#, toolCalls: []) }
                return .init(content: #"{"steps":[{"id":"same","role":"Executor","title":"Create the owned output once"}]}"#, toolCalls: [])
            }
            if role.contains("ROLE: Executor") {
                executors += 1
                if resuming { resumeRoles.append("executor") }
                if pauseExecutorReply { executorWaiting = true; await withCheckedContinuation { executorContinuation = $0 } }
                if sequentialSteps, payload.contains("Active action step: Create the second owned output once") {
                    return .init(content: "", toolCalls: [.init(id: "reused-transport-id", name: "write_file", arguments: ["path": .string(second.path), "content": .string("SECOND")])])
                }
                let first = ToolCall(id: "reused-transport-id", name: "write_file", arguments: ["path": .string(output.path), "content": .string(String(decoding: expected, as: UTF8.self))])
                if partialBatch {
                    let secondCall = ToolCall(id: "second-transport-id", name: "write_file", arguments: ["path": .string(second.path), "content": .string("SECOND")])
                    return .init(content: "", toolCalls: [first, secondCall])
                }
                return .init(content: "", toolCalls: [first])
            }
            if !tools.isEmpty {
                #expect(role.contains("ROLE: Critic"))
                #expect(tools.allSatisfy { ToolPartitioning.allowedToolNames(for: .critic).contains($0.name) })
                if resuming { resumeRoles.append("critic-read") }
                if sequentialSteps, payload.contains("Evaluated step: Create the second owned output once") {
                    return .init(content: "Read the current second output.", toolCalls: [.init(id: "reused-transport-id", name: "read_file", arguments: ["path": .string(second.path)])])
                }
                let first = ToolCall(id: "reused-transport-id", name: "read_file", arguments: ["path": .string(output.path)])
                let secondCall = ToolCall(id: "second-read-id", name: "read_file", arguments: ["path": .string(second.path)])
                return .init(content: "Read current complete state before any verdict.", toolCalls: partialBatch ? [first, secondCall] : [first])
            }
            verdicts += 1
            if resuming { resumeRoles.append("critic-verdict") }
            let raw = try #require(input.first { $0.role == "tool" && $0.toolName == "read_file" }?.content.data(using: .utf8))
            let object = try JSONDecoder().decode(JSONValue.self, from: raw)
            let actual = try #require(object.object?["summary"]?.string)
            #expect(Data(actual.utf8) == lastRead)
            let target = sequentialSteps && payload.contains("Evaluated step: Create the second owned output once") ? Data("SECOND".utf8) : expected
            return .init(content: Data(actual.utf8) == target ? "VERIFIED: Exact current owned bytes match." : "UNVERIFIED: The current owned bytes differ.", toolCalls: [])
        }

        func action(_ call: ToolCall) async throws -> ToolResult {
            let path = try #require(call.arguments["path"]?.string)
            if call.name == "write_file" {
                writtenPaths.append(path)
                let text = try #require(call.arguments["content"]?.string)
                try Data(text.utf8).write(to: URL(fileURLWithPath: path))
                if pauseWriteReturn { writeWaiting = true; await withCheckedContinuation { writeContinuation = $0 } }
                if writtenPaths.count == 1, let fault { await journal.injectFault(fault) }
                return .init(summary: receiptMarker, evidence: "Exact owned write readback: " + String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self), verified: true, artifactPath: path)
            }
            #expect(call.name == "read_file")
            reads += 1
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                return .init(summary: "Owned output is absent", evidence: "The requested owned file does not exist.", verified: false)
            }
            // Use the actual plain-UTF8 production adapter, not a generic
            // verified string. The upcoming one-verdict source proof must bind
            // these exact returned summary bytes to the real selected file.
            fileTools.grants = store.grants
            let actual = try await fileTools.execute(call)
            #expect(Data(actual.summary.utf8) == bytes)
            lastRead = bytes
            return actual
        }

        func records() async throws -> [JournalRecord] {
            let scope = try await journal.scope()
            var cursor: JournalCursor?, all: [JournalRecord] = []
            repeat {
                let page = try await journal.page(after: cursor, expectedScope: scope)
                all += page.records; cursor = page.hasLater ? page.cursor : nil
            } while cursor != nil
            return all
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw RelayError.message("Owned step checkpoint test did not reach its boundary.") }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        func releaseAll() {
            executorContinuation?.resume(); executorContinuation = nil
            writeContinuation?.resume(); writeContinuation = nil
            pauseExecutorReply = false; pauseWriteReturn = false
        }
        func removeOwnedFiles() { try? FileManager.default.removeItem(at: root) }
    }
}

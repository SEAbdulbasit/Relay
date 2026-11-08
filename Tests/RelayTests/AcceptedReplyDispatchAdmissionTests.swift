import Foundation
import Testing
@preconcurrency import LiteRTLM
@testable import Relay
@testable import RelayJournal

@MainActor private final class AcceptedSourceScope {
    var context: MultiAgentContinuation.Context
    var grants: [ScopeGrant]
    var active = true
    init(context: MultiAgentContinuation.Context, grants: [ScopeGrant]) { self.context = context; self.grants = grants }
}
@MainActor private final class AcceptedSourceFixture {
    let root: URL, input: URL, output: URL
    let history: AssistantConversationHistory
    let run: AssistantConversationHistory.Run
    let worker: SelectedFileProofWorker
    let book: MultiAgentContinuation
    let scope: AcceptedSourceScope
    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-accepted-source-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let chosen = directory.appendingPathComponent("source.txt")
        try Data("OWNED_SOURCE_A_你好\n".utf8).write(to: chosen)
        root = directory; input = chosen; output = directory.appendingPathComponent("output.txt")
        history = AssistantConversationHistory(stateURL: directory.appendingPathComponent("state.json"))
        let context = MultiAgentContinuation.Context(logicalTaskID: UUID(), configuration: .init(), scopeID: UUID(), sourceRevision: 0)
        run = try .init(logicalTaskID: context.logicalTaskID, cause: .newRequest)
        let fileWorker = SelectedFileProofWorker(timeout: .seconds(5))
        worker = fileWorker; book = MultiAgentContinuation(worker: fileWorker)
        scope = AcceptedSourceScope(context: context, grants: [.init(path: directory.path, writable: true)])
        book.startTask(context.logicalTaskID)
    }
    func actualReadReceipt() async throws -> (Relay.ToolCall, ToolResult) {
        let call = Relay.ToolCall(id: "actual-read", name: "read_file", arguments: ["path": .string(input.path)])
        let prepared = try await book.prepare(call, proposalID: UUID(), run: run, context: scope.context, grants: { self.scope.grants })
        let tools = MacTools(); tools.grants = scope.grants
        let result = try await tools.execute(call)
        await book.record(result, prepared: prepared, grants: { self.scope.grants }); book.acknowledge(prepared)
        return (call, result)
    }
    func snapshot(runID: UUID? = nil) async throws -> MultiAgentContinuation.Snapshot {
        try await book.snapshot(context: scope.context, validationRunID: runID ?? run.taskID, isCurrent: { self.scope.active })
    }
    func fresh(_ call: Relay.ToolCall, _ result: ToolResult, runID: UUID? = nil) async throws -> ModelInputSourceProof {
        try await book.freshReadbackSourceProof(call: call, result: result, context: scope.context,
            validationRunID: runID ?? run.taskID, grants: { self.scope.grants },
            currentContext: { self.scope.context }, isCurrent: { self.scope.active })
    }
}
@MainActor private func withAcceptedSourceFixture(_ body: @MainActor (AcceptedSourceFixture) async throws -> Void) async throws {
    let fixture = try AcceptedSourceFixture()
    do {
        try await body(fixture)
        fixture.scope.active = false; await fixture.worker.drain(); try await fixture.history.close()
        try FileManager.default.removeItem(at: fixture.root)
    } catch {
        fixture.scope.active = false; await fixture.worker.drain(); try? await fixture.history.close()
        try? FileManager.default.removeItem(at: fixture.root); throw error
    }
}
private final class AcceptedIntentBarrier: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var entered = false, expired = false
    var isEntered: Bool { lock.withLock { entered } }
    var timedOut: Bool { lock.withLock { expired } }
    func pause() { lock.withLock { entered = true }; if semaphore.wait(timeout: .now() + 5) == .timedOut { lock.withLock { expired = true } } }
    func release() { semaphore.signal() }
}
@MainActor private func awaitAcceptedIntent(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw RelayError.message("Owned intent did not reach the actual SQLite boundary.") }
        try await Task.sleep(for: .milliseconds(2))
    }
}
@MainActor private func acceptedIntentRecords(_ journal: ConversationJournal) async throws -> [JournalRecord] {
    let scope = try await journal.scope(); var records: [JournalRecord] = [], cursor: JournalCursor?
    repeat {
        let page = try await journal.page(after: cursor, expectedScope: scope)
        records += page.records; cursor = page.hasLater ? page.cursor : nil
    } while cursor != nil
    return records
}

/// Owned selected files, actual MacTools and real SQLite. Model completions are
/// inert deterministic proposals only; no weights, private apps or input run.
@MainActor @Suite(.serialized) struct AcceptedReplyDispatchAdmissionTests {
    @Test func actualIncludedSourceChangingDuringIntentCommitProducesTypedNonDispatchBeforeMacToolsWrite() async throws {
        try await withAcceptedSourceFixture { f in
            _ = try await f.actualReadReceipt()
            let snapshot = try await f.snapshot(), proof = try #require(snapshot.sourceProof)
            try await proof.validate()
            try await f.history.prepare(f.run)
            let journal = try await f.history.journalForTesting(), barrier = AcceptedIntentBarrier()
            defer { barrier.release() }
            let call = Relay.ToolCall(id: "accepted-write", name: "write_file", arguments: ["path": .string(f.output.path), "content": .string("ACCEPTED_FROM_A")])
            var writes = 0, actionClassifications = 0
            await journal.atNextBoundary(.beforeCommit) { barrier.pause() }
            let pending = Task { @MainActor in
                try await f.history.perform(call, proposalID: UUID(), run: f.run, validate: {}, admitAction: proof.validator,
                    action: {
                        writes += 1
                        let tools = MacTools(); tools.grants = f.scope.grants
                        return try await tools.execute(call)
                    }, result: { $0 }, unsavedResult: { _ in Issue.record("No action result exists before admission.") },
                    failureOutcome: { _, intent in actionClassifications += 1; return .init(intent: intent, kind: .effectUncertain) })
            }
            do {
                try await awaitAcceptedIntent { barrier.isEntered }
                try Data("OWNED_SOURCE_B_你好\n".utf8).write(to: f.input)
                barrier.release()
                await #expect(throws: SelectedFileProofWorker.Failure.unsafeSource) { _ = try await pending.value }
                #expect(!barrier.timedOut && writes == 0 && actionClassifications == 0)
                #expect(!FileManager.default.fileExists(atPath: f.output.path))
                let records = try await acceptedIntentRecords(journal)
                guard case let .result(outcome) = records.last?.event.payload else { throw JournalError.invalidEvent }
                #expect(outcome.kind == .notDispatched)
                #expect(records.filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
                #expect(records.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
            } catch {
                pending.cancel(); barrier.release(); _ = await pending.result; throw error
            }
        }
    }

    @Test(arguments: ["source", "grants", "configuration", "stop"])
    func theRealStoreRetainsTheAcceptedReplyProofThroughItsSQLiteIntentAwait(_ change: String) async throws {
        try await withAcceptedSourceFixture { f in
            let journal = try await f.history.journalForTesting(), barrier = AcceptedIntentBarrier()
            defer { barrier.release() }
            var reads = 0, writes = 0, executorReplies = 0, sawActualSource = false
            let store = AssistantStore(persistenceURL: nil, complete: { @MainActor input, _, _ in
                let role = input.first?.content ?? ""
                if role.contains("ROLE: Planner") {
                    return ModelReply(content: #"{"steps":[{"role":"Navigator","title":"Read selected source"},{"role":"Executor","title":"Create output from that source"}]}"#, toolCalls: [])
                }
                if role.contains("ROLE: Navigator") {
                    return ModelReply(content: "", toolCalls: [.init(id: "read-A", name: "read_file", arguments: ["path": .string(f.input.path)])])
                }
                if role.contains("ROLE: Executor") {
                    executorReplies += 1
                    sawActualSource = input.contains { $0.content.contains("OWNED_SOURCE_A_你好") }
                    await journal.atNextBoundary(.afterCommit) { barrier.pause() }
                    return ModelReply(content: "", toolCalls: [.init(id: "write-A", name: "write_file", arguments: ["path": .string(f.output.path), "content": .string("ACCEPTED_FROM_A")])])
                }
                Issue.record("No Critic or re-planner may run after refused accepted-source dispatch.")
                return ModelReply(content: "UNVERIFIED: no dispatch", toolCalls: [])
            }, conversationHistory: f.history, continuationProofWorker: f.worker, execute: { @MainActor call in
                if call.name == "read_file" { reads += 1 }
                if call.name == "write_file" { writes += 1 }
                let tools = MacTools(); tools.grants = f.scope.grants
                return try await tools.execute(call)
            }, multiAgent: true)
            await store.waitForConversationTaskToSettle()
            store.grants = f.scope.grants
            store.draft = "Read the selected source and create the selected output from its current facts."
            store.send()
            do {
                try await awaitAcceptedIntent { barrier.isEntered }
                switch change {
                case "source": try Data("OWNED_SOURCE_B_你好\n".utf8).write(to: f.input)
                case "grants": store.grants = []
                case "configuration": store.configuration.model = "another-model"
                default: store.stop()
                }
                barrier.release(); await store.waitForConversationTaskToSettle()
                #expect(!barrier.timedOut && sawActualSource && reads == 1 && executorReplies == 1 && writes == 0)
                #expect(!FileManager.default.fileExists(atPath: f.output.path))
                #expect(store.phase == (change == "stop" ? .stopped : (change == "source" ? .failed : .stopped)))
                let records = try await acceptedIntentRecords(journal)
                let writeIntents = records.compactMap { record -> JournalIntent? in
                    if case let .intent(intent) = record.event.payload, intent.toolName == "write_file" { return intent }; return nil
                }
                let intent = try #require(writeIntents.first); #expect(writeIntents.count == 1)
                let outcomes = records.compactMap { record -> JournalToolOutcome? in
                    if case let .result(outcome) = record.event.payload, outcome.invocationID == intent.invocationID { return outcome }; return nil
                }
                #expect(outcomes.count == 1 && outcomes.first?.kind == .notDispatched)
            } catch {
                store.stop(); barrier.release(); await store.waitForConversationTaskToSettle(); throw error
            }
        }
    }

    @Test func omittedStaleSourceLeavesDoNotBlockAnIndependentGoalOnlyWrite() async throws {
        try await withAcceptedSourceFixture { f in
            _ = try await f.actualReadReceipt()
            try Data("STALE_SOURCE_B\n".utf8).write(to: f.input)
            let snapshot = try await f.snapshot()
            #expect(snapshot.included == 0 && snapshot.omitted == 1 && snapshot.sourceProof == nil)
            #expect(!snapshot.modelContext.contains("OWNED_SOURCE_A_你好"))
            try await snapshot.validate()
            let call = Relay.ToolCall(id: "goal-only", name: "write_file", arguments: ["path": .string(f.output.path), "content": .string("LITERAL_USER_GOAL_ONLY")])
            var effects = 0
            let result = try await f.history.perform(call, proposalID: UUID(), run: f.run, validate: {},
                admitAction: snapshot.sourceProof?.validator, action: {
                    effects += 1; let tools = MacTools(); tools.grants = f.scope.grants
                    return try await tools.execute(call)
                }, result: { $0 }, unsavedResult: { _ in Issue.record("Owned local SQLite should settle this result.") })
            #expect(effects == 1 && result.verified)
            #expect(try Data(contentsOf: f.output) == Data("LITERAL_USER_GOAL_ONLY".utf8))
        }
    }
}

@MainActor @Suite(.serialized) struct ContinuationSourceLeafIdentityTests {
    @Test func actualIncludedLeavesDeduplicateWithinOneRunButSeparateResumeRunsAndFreshPurpose() async throws {
        try await withAcceptedSourceFixture { f in
            let (call, result) = try await f.actualReadReceipt()
            var merged: ModelInputSourceProof?
            for _ in 0..<40 {
                let snapshot = try await f.snapshot()
                merged = try ModelInputSourceProof.merging([merged, snapshot.sourceProof])
            }
            #expect(merged?.dependencyCount == 1); try await merged?.validate()
            let fresh = try await f.fresh(call, result)
            let freshAgain = try await f.fresh(call, result)
            #expect(try ModelInputSourceProof.merging([fresh, freshAgain])?.dependencyCount == 1)
            #expect(try ModelInputSourceProof.merging([merged, fresh])?.dependencyCount == 2)
            let resumedRun = try AssistantConversationHistory.Run(logicalTaskID: f.scope.context.logicalTaskID, predecessor: f.run, cause: .resume)
            let resumed = try await f.snapshot(runID: resumedRun.taskID)
            #expect(try ModelInputSourceProof.merging([merged, resumed.sourceProof])?.dependencyCount == 2)
            let resumedFresh = try await f.fresh(call, result, runID: resumedRun.taskID)
            #expect(try ModelInputSourceProof.merging([fresh, resumedFresh])?.dependencyCount == 2)
        }
    }
    @Test func emptyAndSourceFreeOperationalReceiptsNeverConsumePerTurnSourceLeaves() async throws {
        try await withAcceptedSourceFixture { f in
            #expect(try await f.snapshot().sourceProof == nil)
            let call = Relay.ToolCall(id: "calculate", name: "calculate", arguments: ["expression": .string("6*7")])
            let prepared = try await f.book.prepare(call, proposalID: UUID(), run: f.run, context: f.scope.context, grants: { [] })
            let tools = MacTools(), result = try await tools.execute(call)
            await f.book.record(result, prepared: prepared, grants: { [] }); f.book.acknowledge(prepared)
            for _ in 0..<40 {
                let snapshot = try await f.snapshot()
                #expect(snapshot.included == 1 && snapshot.sourceProof == nil)
            }
        }
    }
}

private enum BoundVisionInertFailure: Error { case unavailable }
@MainActor private final class BoundVisionInertRuntime: LocalModelRuntime {
    var onCreate: (() throws -> Void)?, onSend: (() throws -> Void)?
    var fail = false, images: [Data] = []
    func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession {
        try onCreate?(); return BoundVisionInertSession(owner: self)
    }
}
@MainActor private final class BoundVisionInertSession: LocalConversationSession {
    let owner: BoundVisionInertRuntime
    init(owner: BoundVisionInertRuntime) { self.owner = owner }
    func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
        for part in message.contents { if case let .imageData(bytes) = part { owner.images.append(bytes) } }
        try owner.onSend?()
        if owner.fail { throw BoundVisionInertFailure.unavailable }
        return .init("Owned inert image answer.", role: .model)
    }
    nonisolated func cancel() {}
}
@MainActor private func boundSyntheticVision() async throws -> NativeVisionPlanningInput {
    let image = try LMStudioVisionProbe.make()
    let frame = try await NativeVisionFrame.prepare(image: .init(data: image.jpeg, mimeType: "image/jpeg",
        width: LMStudioVisionProbe.width, height: LMStudioVisionProbe.height), observationID: UUID())
    return try .init(frame: frame, sourceIsCurrent: { true })
}
@MainActor private func selectBoundConfiguration(_ configuration: ModelConfiguration, fixture f: AcceptedSourceFixture) {
    let prior = f.scope.context
    f.scope.context = .init(logicalTaskID: prior.logicalTaskID, configuration: configuration,
        scopeID: prior.scopeID, sourceRevision: prior.sourceRevision)
}

/// Synthetic pixels and inert runtime/transport only. The asynchronous private
/// input dependency is an actual selected-file source proof, not a Boolean spy.
@MainActor @Suite(.serialized) struct BoundVisionSourceAdmissionTests {
    @Test(arguments: ["before-load", "during-load", "after-create"])
    func embeddedVisionRechecksTheActualInputSourceBeforeAnyPrivateImageSend(_ boundary: String) async throws {
        try await withAcceptedSourceFixture { f in
            let model = f.root.appendingPathComponent("inert.litertlm"); try Data([1]).write(to: model)
            let configuration = ModelConfiguration(modelPath: model.path)
            selectBoundConfiguration(configuration, fixture: f)
            _ = try await f.actualReadReceipt()
            let proof = try #require(try await f.snapshot().sourceProof)
            let runtime = BoundVisionInertRuntime(); var loads = 0
            let change: @MainActor () throws -> Void = { try Data("REVOKED_INPUT_SOURCE".utf8).write(to: f.input) }
            if boundary == "after-create" { runtime.onCreate = change }
            let embedded = LocalModelClient(runtimeFactory: nil, visionRuntimeFactory: { _, _, _ in
                loads += 1; if boundary == "during-load" { try change() }; return runtime
            })
            let router = LocalInferenceRouter(embedded: embedded), vision = try await boundSyntheticVision()
            if boundary == "before-load" { try change() }
            await #expect(throws: SelectedFileProofWorker.Failure.unsafeSource) {
                try await router.complete(messages: [.init(role: "user", content: "Owned source-derived image question.")],
                    tools: [], configuration: configuration, vision: vision, sourceAuthorization: proof.validator)
            }
            #expect(runtime.images.isEmpty && loads == (boundary == "before-load" ? 0 : 1))
            router.unload(); await router.drain()
        }
    }

    @Test(arguments: [false, true]) func embeddedVisionFencesBothLateSuccessAndErrorWithTheExactActualSource(_ fail: Bool) async throws {
        try await withAcceptedSourceFixture { f in
            let model = f.root.appendingPathComponent("inert.litertlm"); try Data([1]).write(to: model)
            let configuration = ModelConfiguration(modelPath: model.path)
            selectBoundConfiguration(configuration, fixture: f)
            _ = try await f.actualReadReceipt(); let proof = try #require(try await f.snapshot().sourceProof)
            let runtime = BoundVisionInertRuntime(); runtime.fail = fail
            runtime.onSend = { try Data("CHANGED_DURING_INFERENCE".utf8).write(to: f.input) }
            let router = LocalInferenceRouter(embedded: LocalModelClient(runtimeFactory: nil, visionRuntimeFactory: { _,_,_ in runtime }))
            let vision = try await boundSyntheticVision()
            await #expect(throws: SelectedFileProofWorker.Failure.unsafeSource) {
                try await router.complete(messages: [.init(role: "user", content: "Owned source-derived image question.")],
                    tools: [], configuration: configuration, vision: vision, sourceAuthorization: proof.validator)
            }
            #expect(runtime.images.count == 1)
            router.unload(); await router.drain()
        }
    }

    @Test(arguments: ["probe", "private-success", "private-error"])
    func endpointVisionRechecksAfterProbeAndBothPrivateReplyPathsWithoutNativeFallback(_ boundary: String) async throws {
        try await withAcceptedSourceFixture { f in
            let configuration = ModelConfiguration(backend: .lmStudio, lmStudio: try .init(endpoint: LMStudioEndpoint(port: 1234), modelID: "synthetic-server-model"))
            selectBoundConfiguration(configuration, fixture: f)
            _ = try await f.actualReadReceipt(); let proof = try #require(try await f.snapshot().sourceProof)
            let probe = try LMStudioVisionProbe.make(), transport = LMStudioIntegrationFixture()
            await transport.setProbeAnswer(probe.expectedMarker)
            let router = LocalInferenceRouter(server: LMStudioClient(transport: transport.transport), visionProbeFactory: { probe })
            if boundary != "probe" { try await router.checkVision(configuration: configuration) }
            await transport.hold()
            let vision = try await boundSyntheticVision()
            let pending = Task { @MainActor in
                try await router.complete(messages: [.init(role: "user", content: "Owned source-derived image question.")],
                    tools: [], configuration: configuration, vision: vision, sourceAuthorization: proof.validator)
            }
            do {
                let expectedRequests = boundary == "probe" ? 1 : 2
                try await awaitLMStudioCondition { await transport.requests.count == expectedRequests }
                try Data("CHANGED_ENDPOINT_SOURCE".utf8).write(to: f.input)
                if boundary == "private-error" { await transport.failNextReply() }
                await transport.release()
                await #expect(throws: SelectedFileProofWorker.Failure.unsafeSource) { _ = try await pending.value }
                await router.drain()
                #expect(await transport.requests.count == expectedRequests && !router.isLoaded)
                router.unload(); await router.drain()
            } catch {
                pending.cancel(); await transport.release(); _ = await pending.result
                router.unload(); await router.drain(); throw error
            }
        }
    }
}

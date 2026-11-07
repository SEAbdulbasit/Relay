import Foundation
import Testing
import Dispatch
@testable import Relay
@testable import RelayJournal

/// Only pauses a real SQLite commit boundary. No database result is replaced.
private final class OwnedJournalBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var expired = false
    var isEntered: Bool { lock.withLock { entered } }
    var timedOut: Bool { lock.withLock { expired } }
    func pause() {
        lock.withLock { entered = true }
        if semaphore.wait(timeout: .now() + 5) == .timedOut { lock.withLock { expired = true } }
    }
    func release() { semaphore.signal() }
}
@MainActor private func waitForJournalFixture(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
    while !condition() {
        guard clock.now < deadline else { throw RelayError.message("Owned journal fixture did not reach its boundary.") }
        try await Task.sleep(for: .milliseconds(2))
    }
}
private func journalFixtureRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("relay-journal-cutover-" + UUID().uuidString) }
@MainActor private func journalRecords(_ core: ConversationJournal) async throws -> [JournalRecord] {
    let scope = try await core.scope(); var cursor: JournalCursor?, records: [JournalRecord] = []
    repeat {
        let page = try await core.page(after: cursor, expectedScope: scope)
        records += page.records; cursor = page.hasLater ? page.cursor : nil
    } while cursor != nil
    return records
}

@MainActor @Suite(.serialized) struct ConversationJournalCutoverTests {
    @Test func resultTransactionRetainsOutputLinkAcrossMissingFinalAssistantMessageAndClear() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = root.appendingPathComponent("owned output.txt"), bytes = Data("preserve this output".utf8); try bytes.write(to:file)
        let state = root.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL:state)
        let core = try await history.journalForTesting(), scope = try await core.scope(), task = UUID(), attempt = UUID()
        _ = try await core.acceptRequest(id:JournalOpaqueID(UUID().uuidString),taskID:task,attemptID:attempt,text:JournalVisibleText("Produce the owned file",origin:.user),relation:JournalRunRelation(logicalTaskID:UUID(),cause:.newRequest),expectedScope:scope)
        let intent = try JournalIntent(proposalID:UUID(),producerEpoch:core.producerEpoch,toolCallID:JournalOpaqueID("output-call"),toolName:"write_file",callDigest:Data(repeating:4,count:32),effect:.mutation)
        _ = try await core.commitIntent(JournalEvent(id:JournalOpaqueID("output-intent"),taskID:task,attemptID:attempt,payload:.intent(intent)),expectedScope:scope)
        let outcome = JournalToolOutcome(intent:intent,kind:.returnedVerified,artifacts:[try JournalArtifactReference(visiblePath:file.path)])
        _ = try await core.commitResult(JournalEvent(id:JournalOpaqueID("output-result"),taskID:task,attemptID:attempt,payload:.result(outcome)),expectedScope:scope)
        // No final assistant message exists. The standalone process gate separately proves WAL crash recovery.
        try await history.close()
        let restored = AssistantStore(persistenceURL:state)
        await restored.waitForConversationTaskToSettle()
        let recovered = try #require(restored.messages.first(where:{$0.artifacts.contains(file.path)}))
        #expect(recovered.text.hasPrefix("Recovered output reference"))
        #expect(try restored.artifactURLForReveal(file.path,messageID:recovered.id).path == file.path)
        restored.memories = [MemoryItem(text:"Keep approved memory")]
        restored.clearConversation(); try await waitForJournalFixture { !restored.isClearingConversation }
        #expect(restored.messages.isEmpty); #expect(restored.memories.map(\.text) == ["Keep approved memory"])
        #expect(try Data(contentsOf:file) == bytes)
    }
    @Test func stableJournalOrderIgnoresEqualAndBackwardClocksBeforeAndAfterRestart() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL: state)
        let store = AssistantStore(persistenceURL: state, conversationHistory: history)
        let first = ChatMessage(role:"user",text:"First staged",date:Date(timeIntervalSince1970:100))
        let delayed = ChatMessage(role:"assistant",text:"Delayed old result",date:Date(timeIntervalSince1970:100))
        let backward = ChatMessage(role:"user",text:"Later steering with backward clock",date:Date(timeIntervalSince1970:10))
        try await store.stageVisibleConversationFixture([first,delayed,backward],deferredUsers:[first.id,backward.id])
        #expect(store.messages.map(\.text) == [first.text,delayed.text,backward.text])
        try await history.close()
        let restored = AssistantStore(persistenceURL: state)
        await restored.waitForConversationTaskToSettle()
        #expect(restored.messages.map(\.text) == [first.text,delayed.text,backward.text])
    }
    @Test func finderRevealAdmissionSurvivesEditsAndRemovedInferenceGrantWithoutReadingContents() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = root.appendingPathComponent("result.txt"); try Data("original".utf8).write(to:file)
        let state = root.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL:state)
        let store = AssistantStore(persistenceURL:state,conversationHistory:history)
        store.grants = [ScopeGrant(path:root.path,writable:true)]
        let message = ChatMessage(role:"assistant",text:"Output available",artifacts:[file.path])
        try await store.stageVisibleConversationFixture([message],deferredUsers:[])
        try Data("edited by the user".utf8).write(to:file); store.grants = []
        #expect(try store.artifactURLForReveal(file.path,messageID:message.id).path == file.path)
        #expect(throws: (any Error).self) { try history.validateArtifactForContentAccess(messageID:message.id,path:file.path,grants:[]) }
        #expect(throws: (any Error).self) { try store.artifactURLForReveal(root.appendingPathComponent("unlisted.txt").path,messageID:message.id) }
    }
    @Test func processRestoreRetainsVisibleHistoryButCannotRemintOriginalNativeScopeOrOldPrompt() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at:root) }
        let state = root.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL:state)
        let first = AssistantStore(persistenceURL:state,complete:{_,_,_ in ModelReply(content:"PRIVATE_OLD_RESPONSE",toolCalls:[])},conversationHistory:history)
        first.draft = "PRIVATE_OLD_REQUEST"; first.send(); await first.waitForConversationTaskToSettle(); try await history.close()
        var nextInput = "", effects = 0
        let second = AssistantStore(persistenceURL:state,complete:{input,_,_ in nextInput = input.map(\.content).joined(separator:"\n"); return ModelReply(content:"Fresh reply",toolCalls:[])},execute:{_ in effects += 1; return ToolResult(summary:"Inert",evidence:"None",verified:true)})
        await second.waitForConversationTaskToSettle()
        #expect(second.messages.contains { $0.text.contains("PRIVATE_OLD_RESPONSE") })
        second.resume(); await second.waitForConversationTaskToSettle()
        #expect(nextInput.isEmpty); #expect(effects == 0); #expect(second.errorMessage?.contains("fresh task") == true)
        second.draft = "A fresh explicit request"; second.send(); await second.waitForConversationTaskToSettle()
        #expect(!nextInput.isEmpty); #expect(!nextInput.contains("PRIVATE_OLD_RESPONSE")); #expect(!nextInput.contains("PRIVATE_OLD_REQUEST"))
    }
    @Test(arguments: [JournalFault.beforeCommit, .afterCommit]) func requestAcknowledgmentFailureRetainsExactDraftAndAdmitsNoAction(_ fault: JournalFault) async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL: state)
        let core = try await history.journalForTesting(); var effects = 0
        let store = AssistantStore(persistenceURL: state, conversationHistory: history,
            execute: { _ in effects += 1; return ToolResult(summary: "Inert", evidence: "No Mac input", verified: true) })
        await store.waitForConversationTaskToSettle()
        await core.injectFault(fault)
        let exact = "\n  open Calculator  \n"
        store.draft = exact; store.send(); await store.waitForConversationTaskToSettle()
        #expect(Data(store.draft.utf8) == Data(exact.utf8)); #expect(effects == 0)
        #expect(!store.messages.contains(where: { $0.role == "user" && Data($0.text.utf8) == Data(exact.utf8) }))
        #expect(store.errorMessage?.contains("preserved") == true)
    }
    @Test func directExactActionHasCommittedIntentBeforeItsInertExecutor() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL: state)
        let core = try await history.journalForTesting(); var effects = 0
        let store = AssistantStore(persistenceURL: state, conversationHistory: history, execute: { call in
            let records = try await journalRecords(core)
            guard case let .intent(intent) = records.last?.event.payload else { throw JournalError.corrupt }
            #expect(intent.toolCallID.bytes == Data(call.id.utf8)); #expect(effects == 0)
            effects += 1; return ToolResult(summary: "Opened synthetic app", evidence: "Inert oracle, no desktop action", verified: true)
        })
        store.draft = "open Calculator"; store.send(); await store.waitForConversationTaskToSettle()
        #expect(effects == 1); #expect(store.draft.isEmpty)
        let records = try await journalRecords(core)
        #expect(records.filter { if case .intent = $0.event.payload { return true }; return false }.count == 1)
        #expect(records.filter { if case .result = $0.event.payload { return true }; return false }.count == 1)
        #expect(records.last?.event.payload == .finished(.responseDelivered))
    }
    @Test func singleAgentSameProviderIDCanReadThenWriteAcrossAcceptedReplies() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("owned.txt"), bytes = Data("before".utf8); try bytes.write(to: file)
        let state = root.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL: state)
        let core = try await history.journalForTesting(); var turns = 0, effects: [String] = []
        let store = AssistantStore(persistenceURL: state, complete: { _, _, _ in
            turns += 1
            if turns == 1 { return ModelReply(content: "", toolCalls: [ToolCall(id: "same-provider-ID", name: "read_file", arguments: ["path":.string(file.path)])]) }
            if turns == 2 { return ModelReply(content: "", toolCalls: [ToolCall(id: "same-provider-ID", name: "write_file", arguments: ["path":.string(file.path), "content":.string("requested")])]) }
            return ModelReply(content: "The synthetic receipts are available.", toolCalls: [])
        }, conversationHistory: history, execute: { call in
            effects.append(call.name); return ToolResult(summary: "Inert " + call.name, evidence: "Owned protocol oracle only", verified: true)
        })
        store.grants = [ScopeGrant(path: root.path, writable: true)]
        store.draft = "Inspect and rewrite the owned fixture."; store.send()
        let reviewer = Task { @MainActor in
            while store.isRunning {
                if store.pendingReview != nil { store.approveReview() }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        await store.waitForConversationTaskToSettle(); reviewer.cancel()
        #expect(effects == ["read_file","write_file"]); #expect(try Data(contentsOf: file) == bytes)
        let intents = try await journalRecords(core).compactMap { record -> JournalIntent? in if case let .intent(value) = record.event.payload { return value }; return nil }
        #expect(intents.count == 2); #expect(intents[0].proposalID != intents[1].proposalID)
        #expect(intents.allSatisfy { $0.toolCallID.bytes == Data("same-provider-ID".utf8) })
    }
    @Test func lostIntentAcknowledgmentStopsThePlannerWithoutDispatchOrRemintedProposal() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL: state)
        let core = try await history.journalForTesting(); var turns = 0, effects = 0
        let store = AssistantStore(persistenceURL: state, complete: { _, _, _ in
            turns += 1; await core.injectFault(.afterCommit)
            return ModelReply(content: "", toolCalls: [ToolCall(id: "one-proposal", name: "calculate", arguments: ["expression":.string("1+1")])])
        }, conversationHistory: history, execute: { _ in effects += 1; return ToolResult(summary: "2", evidence: "Inert", verified: true) })
        store.draft = "Compute the owned expression."; store.send(); await store.waitForConversationTaskToSettle()
        #expect(turns == 1); #expect(effects == 0); #expect(store.phase == .failed)
        let intents = try await journalRecords(core).filter { if case .intent = $0.event.payload { return true }; return false }
        #expect(intents.count == 1)
    }
    @Test func failedResultSaveRetainsKnownPairAndResumeRetriesOnlyStorage() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at:root) }
        let state = root.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL:state)
        let core = try await history.journalForTesting(); var turns = 0, effects = 0, resumedInput:[ModelMessage] = []
        let store = AssistantStore(persistenceURL:state,complete:{input,_,_ in
            turns += 1
            if turns == 1 { return ModelReply(content:"",toolCalls:[ToolCall(id:"save-once",name:"calculate",arguments:["expression":.string("2+2")])]) }
            resumedInput = input
            return ModelReply(content:"The known result remains available.",toolCalls:[])
        },conversationHistory:history,execute:{_ in
            effects += 1; await core.injectFault(.beforeCommit)
            return ToolResult(summary:"KNOWN_RESULT_4",evidence:"Owned inert oracle",verified:true)
        })
        store.draft = "Compute once and retain the known outcome."; store.send(); await store.waitForConversationTaskToSettle()
        #expect(store.phase == .failed); #expect(turns == 1); #expect(effects == 1)
        #expect(store.messages.last?.text.contains("KNOWN_RESULT_4") == true)
        #expect(store.errorMessage?.contains("preserved") == true)
        store.resume(); await store.waitForConversationTaskToSettle()
        #expect(effects == 1); #expect(!resumedInput.isEmpty && ContextWindow.isWellFormed(resumedInput))
        let settled = resumedInput.filter { $0.role == "tool" && $0.toolCallID?.utf8.elementsEqual("save-once".utf8) == true }
        #expect(settled.count == 1); #expect(settled.first?.content.contains("KNOWN_RESULT_4") == true)
        let results = try await journalRecords(core).filter { if case .result = $0.event.payload { return true }; return false }
        #expect(results.count == 1)
    }
    @Test(arguments: ["intent", "action", "result"]) func steeringDrainsEachRealCheckpointBoundaryWithoutDroppingConstraint(_ boundary: String) async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL: state)
        let core = try await history.journalForTesting(), barrier = OwnedJournalBarrier()
        var turns = 0, effects = 0, enteredAction = false, releaseAction: CheckedContinuation<Void,Never>?, nextInput = ""
        let store = AssistantStore(persistenceURL: state, complete: { input, _, _ in
            turns += 1
            if turns == 1 {
                if boundary == "intent" { await core.atNextBoundary(.beforeCommit) { barrier.pause() } }
                return ModelReply(content: "", toolCalls: [ToolCall(id:"reused-ID", name:"calculate", arguments:["expression":.string("1+1")])])
            }
            if turns == 2 {
                nextInput = input.map(\.content).joined(separator:"\n")
                return ModelReply(content:"", toolCalls:[ToolCall(id:"reused-ID", name:"calculate", arguments:["expression":.string("2+2")])])
            }
            return ModelReply(content:"The inert results are recorded.",toolCalls:[])
        }, conversationHistory: history, execute: { call in
            effects += 1
            if call.arguments["expression"]?.string == "1+1" {
                if boundary == "action" { enteredAction = true; await withCheckedContinuation { releaseAction = $0 } }
                if boundary == "result" { await core.atNextBoundary(.beforeCommit) { barrier.pause() } }
            }
            return ToolResult(summary:"Checked inert " + (call.arguments["expression"]?.string ?? ""),evidence:"No Mac input",verified:true)
        })
        store.draft = "Calculate the owned value."; store.send()
        try await waitForJournalFixture { boundary == "action" ? enteredAction : barrier.isEntered }
        let constraint = "Preserve the existing draft and check the second value."
        store.draft = constraint; store.send()
        #expect(turns == 1); #expect(Data(store.draft.utf8) == Data(constraint.utf8))
        if boundary == "action" { releaseAction?.resume() } else { barrier.release() }
        await store.waitForConversationTaskToSettle()
        #expect(!barrier.timedOut); #expect(nextInput.contains(constraint)); #expect(effects == (boundary == "intent" ? 1 : 2))
        let records = try await journalRecords(core)
        let relations = records.compactMap { record -> JournalRunRelation? in if case let .started(_, relation) = record.event.payload { return relation }; return nil }
        #expect(relations.count == 2); #expect(relations[0].logicalTaskID == relations[1].logicalTaskID); #expect(relations[1].cause == .steering)
        #expect(records.contains { if case let .user(text) = $0.event.payload { return Data(text.text.utf8) == Data(constraint.utf8) }; return false })
    }
    @Test func sameProcessStopResumeKeepsScopeAndUnsentDraftWithoutRepeatingSettledAction() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state.json"), history = AssistantConversationHistory(stateURL: state)
        let core = try await history.journalForTesting(); var turns = 0, effects = 0, release: CheckedContinuation<Void,Never>?
        let store = AssistantStore(persistenceURL: state, complete: { _, _, _ in
            turns += 1
            return turns == 1 ? ModelReply(content:"",toolCalls:[ToolCall(id:"once",name:"calculate",arguments:["expression":.string("3+3")])]) : ModelReply(content:"The prior receipt is retained.",toolCalls:[])
        }, conversationHistory: history, execute: { _ in
            effects += 1; await withCheckedContinuation { release = $0 }
            return ToolResult(summary:"6",evidence:"Owned inert oracle",verified:true)
        })
        store.draft = "Compute once."; store.send(); try await waitForJournalFixture { release != nil }
        let unsent = "Keep this unsent draft exactly cafe\u{301}."
        store.draft = unsent; store.stop(); store.resume(); #expect(effects == 1)
        release?.resume(); await store.waitForConversationTaskToSettle()
        #expect(effects == 1); #expect(Data(store.draft.utf8) == Data(unsent.utf8))
        let relations = try await journalRecords(core).compactMap { record -> JournalRunRelation? in if case let .started(_, relation) = record.event.payload { return relation }; return nil }
        #expect(relations.count == 2); #expect(relations[0].logicalTaskID == relations[1].logicalTaskID); #expect(relations[1].cause == .resume)
    }
    @Test func multiAgentPassesDistinctAcceptedProposalIDsAndNeverUsesLegacyHandler() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        try history.stage(ChatMessage(role:"user",text:"Inspect then rewrite the synthetic source."),run:run,grants:[]); _ = try await history.flush()
        var planners = 0, legacy = 0, effects:[String] = [], proposals:[UUID] = []
        let orchestrator = MultiAgentOrchestrator(complete: { input, _, _ in
            let system = input.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                planners += 1
                return ModelReply(content:planners == 1 ? "{\"steps\":[{\"role\":\"Navigator\",\"title\":\"Inspect source\"},{\"role\":\"Executor\",\"title\":\"Rewrite source\"}]}" : "Synthetic receipts ready.",toolCalls:[])
            }
            if system.contains("ROLE: Critic") { return ModelReply(content:"VERIFIED: Inert receipts",toolCalls:[]) }
            return ModelReply(content:"",toolCalls:[system.contains("ROLE: Navigator")
                ? ToolCall(id:"same",name:"list_files",arguments:["path":.string("/synthetic")])
                : ToolCall(id:"same",name:"write_file",arguments:["path":.string("/synthetic/owned.txt"),"content":.string("new")])])
        }, execute: { _ in legacy += 1; throw JournalError.invalidTransition }, executeProposal: { call, proposalID in
            proposals.append(proposalID)
            return try await history.perform(call,proposalID:proposalID,run:run,validate:{},action:{ effects.append(call.name); return ToolResult(summary:"Inert",evidence:"No file or Mac input",verified:true) },result:{$0},unsavedResult:{_ in Issue.record("Unexpected save failure")})
        })
        _ = try await orchestrator.executeTask(goal:"Inspect then rewrite the synthetic source")
        #expect(legacy == 0); #expect(effects == ["list_files","write_file"]); #expect(Set(proposals).count == 2)
        let intents = try await journalRecords(core).compactMap { record -> JournalIntent? in if case let .intent(value) = record.event.payload { return value }; return nil }
        #expect(intents.count == 2); #expect(intents[0].proposalID != intents[1].proposalID)
    }
}

@MainActor @Suite(.serialized) struct ConversationDeliveryCheckpointTests {
    @Test func initialBatchLostAcknowledgmentCanRetryExactStartAndMessageWithoutDispatch() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json"))
        let core = try await history.journalForTesting(), run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        let one = ChatMessage(role: "user", text: "  Exact cafe\u{301} prose  ", date: Date(timeIntervalSince1970: 100))
        try history.stage(one, run: run, grants: [])
        await core.injectFault(.afterCommit)
        await #expect(throws: JournalError.acknowledgmentLost) { try await history.flush() }
        try await Task.sleep(for: .milliseconds(5))
        #expect(try await history.flush() == [one.id])
        let records = try await journalRecords(core)
        #expect(records.count == 2)
        #expect(records.last?.event.payload == .user(try JournalVisibleText(one.text, origin: .user)))
        #expect(!records.contains { if case .intent = $0.event.payload { true } else { false } })
    }
    @Test func standaloneStartAndFinishLostAcknowledgmentsRetryImmutableEventsAndRefuseChangedOutcome() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        await core.injectFault(.afterCommit)
        await #expect(throws: JournalError.acknowledgmentLost) { try await history.prepare(run) }
        try await Task.sleep(for: .milliseconds(5)); try await history.prepare(run)
        await core.injectFault(.afterCommit)
        await #expect(throws: JournalError.acknowledgmentLost) { try await history.finish(run, outcome: .needsInput) }
        try await Task.sleep(for: .milliseconds(5)); try await history.retryResultSaves()
        await #expect(throws: JournalError.conflictingID) { try await history.finish(run, outcome: .responseDelivered) }
        let records = try await journalRecords(core)
        #expect(records.count == 2); #expect(records.last?.event.payload == .finished(.needsInput))
    }
    @Test func unchangedHomeReturnReusesPendingTicketWhileEditedSteeringHasItsOwnAcknowledgment() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _,_,_ in turns += 1; return ModelReply(content: "Synthetic response", toolCalls: []) }, conversationHistory: history)
        await store.waitForConversationTaskToSettle()
        let barrier = OwnedJournalBarrier(); await core.atNextBoundary(.beforeCommit) { barrier.pause() }
        store.draft = "First unchanged request cafe\u{301}"
        let first = try #require(store.send()), duplicate = try #require(store.send())
        #expect(first === duplicate)
        try await waitForJournalFixture { barrier.isEntered }
        #expect(first.status == .pending && turns == 0); #expect(store.messages.isEmpty)
        store.draft = "A genuinely edited steering request"
        let second = try #require(store.send()); #expect(second !== first)
        barrier.release(); await store.waitForConversationTaskToSettle()
        #expect(first.status == .saved && second.status == .saved)
        #expect(store.draft.isEmpty); #expect(turns == 1)
        #expect(store.messages.filter { $0.role == "user" }.map(\.id) == [first.messageID, second.messageID])
        let records = try await journalRecords(core)
        #expect(records.filter { if case .user = $0.event.payload { true } else { false } }.count == 2)
        // The same words are a legitimate new request after the previous acknowledgment.
        store.draft = first.text
        let later = try #require(store.send()); await store.waitForConversationTaskToSettle()
        #expect(later.messageID != first.messageID && later.status == .saved)
    }
    @Test(arguments: ["success", "stop", "sleep"]) func sidekickAcknowledgmentPreservesIndependentAndEditedDrafts(_ mode: String) async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _,_,_ in turns += 1; return ModelReply(content: "Synthetic Sidekick response", toolCalls: []) }, conversationHistory: history)
        store.actionsReady = true; await store.waitForConversationTaskToSettle()
        let controller = NotchOverlayController(), barrier = OwnedJournalBarrier()
        store.draft = "Independent Home text"
        let exact = "  Sidekick request cafe\u{301}  "
        controller.promptText = exact
        await core.atNextBoundary(.beforeCommit) { barrier.pause() }
        controller.submit(store: store)
        let ticket = try #require(controller.pendingSubmission)
        controller.submit(store: store)
        try await waitForJournalFixture { barrier.isEntered }
        #expect(controller.pendingSubmission === ticket); #expect(ticket.status == .pending)
        #expect(controller.submittedMessageID == nil && controller.promptText.utf8.elementsEqual(exact.utf8))
        #expect(store.draft == "Independent Home text" && turns == 0 && store.messages.isEmpty)
        store.draft = "Edited independent Home text"
        controller.promptText = "Edited Sidekick text"
        if mode == "stop" { store.stop() }
        if mode == "sleep" { store.setInteractiveSessionActive(false) }
        barrier.release(); await store.waitForConversationTaskToSettle()
        try await waitForJournalFixture { controller.pendingSubmission == nil }
        #expect(store.draft == "Edited independent Home text" && controller.promptText == "Edited Sidekick text")
        #expect(!barrier.timedOut)
        if mode == "success" {
            #expect(ticket.status == .saved && controller.submittedMessageID == ticket.messageID && turns == 1)
            #expect(store.messages.first(where: { $0.id == ticket.messageID })?.text.utf8.elementsEqual(exact.utf8) == true)
        } else { #expect(ticket.status == .stopped && controller.submittedMessageID == nil && turns == 0) }
    }
    @Test(arguments: [JournalFault.beforeCommit, .afterCommit]) func sidekickStorageFailureRetainsTextAndStorageOnlyRepairDoesNotRunTask(_ fault: JournalFault) async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _,_,_ in turns += 1; return ModelReply(content: "Unexpected", toolCalls: []) }, conversationHistory: history)
        store.actionsReady = true; await store.waitForConversationTaskToSettle()
        let controller = NotchOverlayController(); controller.promptText = "Exact failed Sidekick text"; store.draft = "Home text"
        await core.injectFault(fault); controller.submit(store: store)
        let ticket = try #require(controller.pendingSubmission)
        await store.waitForConversationTaskToSettle(); try await waitForJournalFixture { controller.pendingSubmission == nil }
        #expect(ticket.status == .failed && controller.promptText == "Exact failed Sidekick text" && store.draft == "Home text")
        #expect(controller.submittedMessageID == nil && controller.errorMessage != nil && turns == 0)
        try await store.retryConversationStorage()
        #expect(turns == 0 && controller.promptText == "Exact failed Sidekick text" && store.draft == "Home text")
        #expect(store.messages.filter { $0.role == "user" }.map(\.id) == [ticket.messageID])
        #expect(try await journalRecords(core).filter { if case .started = $0.event.payload { true } else { false } }.count == 1)
    }
    @Test func homeStopBeforeLateAcknowledgmentNeverClearsTheEditedDraft() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _,_,_ in turns += 1; return ModelReply(content: "Unexpected", toolCalls: []) }, conversationHistory: history)
        await store.waitForConversationTaskToSettle()
        let barrier = OwnedJournalBarrier(); await core.atNextBoundary(.afterCommit) { barrier.pause() }
        store.draft = "Old exact draft"; let ticket = try #require(store.send())
        try await waitForJournalFixture { barrier.isEntered }
        store.stop(); store.draft = "New edited draft"
        barrier.release(); await store.waitForConversationTaskToSettle()
        #expect(ticket.status == .stopped && store.draft == "New edited draft" && turns == 0)
    }
}

@MainActor @Suite(.serialized) struct JournalTypedOutcomeBridgeTests {
    enum KnownFailure: Error, Equatable { case denied, unexpected }
    @Test(arguments: ["verified", "focus", "known-denial", "unknown-error", "forged", "invalid-artifact"]) func typedOutcomeOnlyClassifiesActualActionFacts(_ mode: String) async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        let call = ToolCall(id: "typed-action", name: "calculate", arguments: ["expression": .string("2+2")])
        var effects = 0, mappedErrors = 0, metadataReports = 0
        let mapping: (@MainActor (ToolResult, JournalIntent) -> JournalToolOutcome)?
        if mode == "invalid-artifact" { mapping = nil }
        else {
            mapping = { _, intent in
                if mode == "forged" {
                    let forged = try! JournalIntent(proposalID: intent.proposalID, producerEpoch: intent.producerEpoch, toolCallID: intent.toolCallID, toolName: intent.toolName, callDigest: intent.callDigest, effect: intent.effect)
                    return JournalToolOutcome(intent: forged, kind: .returnedVerified)
                }
                return JournalToolOutcome(intent: intent, kind: mode == "focus" ? .returnedUnverified : .returnedVerified)
            }
        }
        do {
            _ = try await history.perform(call, proposalID: UUID(), run: run, validate: {}, action: {
                effects += 1
                if mode == "known-denial" { throw KnownFailure.denied }
                if mode == "unknown-error" { throw KnownFailure.unexpected }
                return ToolResult(summary: "Known factual output", evidence: "Inert oracle", verified: true, artifactPath: mode == "invalid-artifact" ? "relative/invalid" : nil)
            }, result: { $0 }, unsavedResult: { _ in Issue.record("Unexpected storage failure") }, journalOutcome: mapping, failureOutcome: { error, intent in
                mappedErrors += 1
                guard let known = error as? KnownFailure, known == .denied else { return nil }
                return JournalToolOutcome(intent: intent, kind: .notDispatched)
            }, metadataFailure: { result in metadataReports += 1; #expect(result.artifactPath == nil && result.summary == "Known factual output") })
            #expect(mode == "verified" || mode == "focus")
        } catch { #expect(["known-denial", "unknown-error", "forged", "invalid-artifact"].contains(mode)) }
        #expect(effects == 1)
        #expect(mappedErrors == (["known-denial", "unknown-error"].contains(mode) ? 1 : 0))
        #expect(metadataReports == (mode == "invalid-artifact" ? 1 : 0))
        let outcomes = try await journalRecords(core).compactMap { record -> JournalToolOutcome? in if case let .result(value) = record.event.payload { value } else { nil } }
        #expect(outcomes.count == 1)
        let expected: JournalOutcomeKind = mode == "known-denial" ? .notDispatched : mode == "verified" ? .returnedVerified : mode == "focus" ? .returnedUnverified : .effectUncertain
        #expect(outcomes.first?.kind == expected)
    }
    @Test(arguments: ["intent", "result"]) func storageFaultIsNotClassifiedAsAnActionFailureAndCannotRepeatAnEffect(_ boundary: String) async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest); try await history.prepare(run)
        let call = ToolCall(id: "once", name: "calculate", arguments: ["expression": .string("2+2")]), proposal = UUID()
        var effects = 0, mappings = 0, observed = 0
        if boundary == "intent" { await core.injectFault(.afterCommit) }
        do {
            _ = try await history.perform(call, proposalID: proposal, run: run, validate: {}, action: {
                effects += 1; await core.injectFault(.afterCommit)
                return ToolResult(summary: "4", evidence: "Inert", verified: true)
            }, result: { $0 }, unsavedResult: { _ in observed += 1 }, failureOutcome: { _,_ in mappings += 1; return nil })
            Issue.record("Expected the actual SQLite acknowledgment fault")
        } catch { #expect(error as? JournalError == .acknowledgmentLost) }
        try await history.retryResultSaves()
        #expect(effects == (boundary == "intent" ? 0 : 1) && mappings == 0 && observed == (boundary == "intent" ? 0 : 1))
        do {
            _ = try await history.perform(call, proposalID: proposal, run: run, validate: {}, action: { effects += 1; return ToolResult(summary: "Unexpected", evidence: "", verified: true) }, result: { $0 }, unsavedResult: { _ in })
            Issue.record("Same proposal regained eligibility")
        } catch { #expect(error as? JournalError == .duplicateIntent) }
        #expect(effects == (boundary == "intent" ? 0 : 1))
    }
    @Test func ordinaryMultiAgentSaveFailureDoesNotCreateAnOrphanGlobalToolResult() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        var effects = 0, turns = 0, inputs: [[ModelMessage]] = []
        let store = AssistantStore(persistenceURL: nil, complete: { messages,_,_ in
            inputs.append(messages); turns += 1
            if turns == 1 { return ModelReply(content: #"{"steps":[{"role":"Navigator","title":"Inspect"}]}"#, toolCalls: []) }
            if turns == 2 { return ModelReply(content: "", toolCalls: [ToolCall(id: "ordinary-multi", name: "list_files", arguments: ["path": .string(root.path)])]) }
            return ModelReply(content: "No further input required.", toolCalls: [])
        }, conversationHistory: history, execute: { _ in effects += 1; await core.injectFault(.beforeCommit); return ToolResult(summary: "KNOWN_MULTI_RESULT", evidence: "Inert", verified: true) }, multiAgent: true)
        store.draft = "Inspect the synthetic folder"; store.send(); await store.waitForConversationTaskToSettle()
        #expect(store.phase == .failed && effects == 1)
        #expect(store.activity.contains { $0.detail.contains("KNOWN_MULTI_RESULT") })
        // Ordinary multi-agent receipts live in the orchestrator blackboard, not the
        // Store's global tool protocol. Resume may synthesize anew, but may not replay.
        store.resume(); await store.waitForConversationTaskToSettle()
        #expect(effects == 1)
        #expect(inputs.allSatisfy { ContextWindow.isWellFormed($0) })
    }
}

@MainActor @Suite(.serialized) struct SidekickSubmissionOwnershipTests {
    @Test(arguments: ["hide", "retire", "newer-home"]) func onlyGenuineRetirementCancelsItsOwnPendingInvocation(_ action: String) async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        var turns = 0, openedHome = false
        let store = AssistantStore(persistenceURL: nil, complete: { _,_,_ in turns += 1; return ModelReply(content: "Synthetic response", toolCalls: []) }, conversationHistory: history)
        store.actionsReady = true; await store.waitForConversationTaskToSettle()
        let suite = "relay-sidekick-delivery-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "relay.sidekick.showInNotch")
        let controller = NotchOverlayController(preferences: defaults, presentsPanels: false)
        controller.connect(store: store, available: true, openWorkspace: { openedHome = true })
        let barrier = OwnedJournalBarrier(); await core.atNextBoundary(.beforeCommit) { barrier.pause() }
        controller.promptText = "Pending Sidekick text"; controller.submit(store: store)
        let sidekick = try #require(controller.pendingSubmission)
        try await waitForJournalFixture { barrier.isEntered }
        var home: ConversationSubmission?
        if action == "hide" { controller.showWorkspace(); #expect(openedHome && sidekick.status == .pending) }
        else {
            if action == "newer-home" { store.draft = "Newer Home request"; home = store.send() }
            controller.connect(store: store, available: false, openWorkspace: {})
            #expect(sidekick.status == .stopped)
            if let home { #expect(home.status == .pending) }
        }
        barrier.release(); await store.waitForConversationTaskToSettle()
        try await waitForJournalFixture { controller.pendingSubmission == nil }
        #expect(!barrier.timedOut)
        if action == "hide" {
            #expect(turns == 1 && sidekick.status == .saved && controller.promptText.isEmpty)
            #expect(controller.submittedMessageID == sidekick.messageID)
            // An acknowledged shared task is independent of surface retirement.
            controller.connect(store: store, available: false, openWorkspace: {})
            #expect(store.phase == .idle && sidekick.status == .saved)
        } else if action == "newer-home" {
            #expect(turns == 1 && home?.status == .saved && controller.promptText == "Pending Sidekick text")
            #expect(store.phase == .idle && store.draft.isEmpty)
        } else { #expect(turns == 0 && controller.promptText == "Pending Sidekick text") }
    }
    @Test func canonicallyEquivalentEditedHomeTextIsNotClearedByAnOlderAcknowledgment() async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        let store = AssistantStore(persistenceURL: nil, complete: { _,_,_ in ModelReply(content: "Synthetic response", toolCalls: []) }, conversationHistory: history)
        await store.waitForConversationTaskToSettle()
        let barrier = OwnedJournalBarrier(); await core.atNextBoundary(.beforeCommit) { barrier.pause() }
        store.draft = "caf\u{e9}"; let ticket = try #require(store.send())
        try await waitForJournalFixture { barrier.isEntered }
        store.draft = "cafe\u{301}"; barrier.release(); await store.waitForConversationTaskToSettle()
        #expect(ticket.status == .saved)
        #expect(Data(store.draft.utf8) == Data("cafe\u{301}".utf8))
        #expect(Data(store.messages.first(where: { $0.id == ticket.messageID })?.text.utf8 ?? "".utf8) == Data("caf\u{e9}".utf8))
    }
}

@MainActor @Suite(.serialized) struct JournalDirectContinuationTests {
    @Test(arguments: ["intent", "result"]) func resumeRepairsStorageWithoutRemintingADirectAction(_ boundary: String) async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        var effects = 0
        let store = AssistantStore(persistenceURL: nil, conversationHistory: history, execute: { _ in
            effects += 1
            if boundary == "result" { await core.injectFault(.afterCommit) }
            return ToolResult(summary: "Known inert app result", evidence: "No actual desktop action", verified: true)
        })
        await store.waitForConversationTaskToSettle()
        if boundary == "intent" { await core.injectIntentFault(.afterCommit) }
        store.draft = "open Calculator"; store.send(); await store.waitForConversationTaskToSettle()
        #expect(store.phase == .failed && effects == (boundary == "intent" ? 0 : 1))
        store.resume(); await store.waitForConversationTaskToSettle()
        #expect(effects == (boundary == "intent" ? 0 : 1))
        #expect(store.messages.last?.text.contains("not repeated") == true)
        #expect(store.phase == (boundary == "intent" ? .needsInput : .idle))
        #expect(try await journalRecords(core).filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
        // A new explicit request has a new task identity and remains eligible.
        store.draft = "open Calculator"; store.send(); await store.waitForConversationTaskToSettle()
        #expect(effects == (boundary == "intent" ? 1 : 2))
    }
}

@MainActor private final class DeliveryVoiceBackend: LocalVoiceBackend {
    var callback: (@MainActor @Sendable (LocalSpeechEvent) -> Void)?
    var starts = 0
    func capability(localeIdentifier: String) -> LocalVoiceCapability { .init(localeSupported: true, onDeviceSupported: true) }
    func requestPermissions() async throws {}
    func begin(localeIdentifier: String, requiresOnDeviceRecognition: Bool, onEvent: @escaping @MainActor @Sendable (LocalSpeechEvent) -> Void) throws { starts += 1; callback = onEvent }
    func stop() {}
}
@MainActor @Suite(.serialized) struct SidekickVoiceDeliveryTests {
    @Test(arguments: ["success", "fault", "stop"]) func finalTranscriptUsesOneCentralTicketAndSurvivesUnacknowledgedDelivery(_ outcome: String) async throws {
        let root = journalFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        let backend = DeliveryVoiceBackend(), voice = LocalVoiceInput(backend: backend, sleepNotificationCenter: NotificationCenter())
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _,_,_ in turns += 1; return ModelReply(content: "Synthetic voice response", toolCalls: []) }, conversationHistory: history, voiceInput: voice)
        store.actionsReady = true; await store.waitForConversationTaskToSettle()
        let name = "relay-voice-delivery-" + UUID().uuidString, preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        preferences.set(false, forKey: "relay.sidekick.showInNotch")
        let controller = NotchOverlayController(preferences: preferences, presentsPanels: false)
        controller.connect(store: store, available: true, openWorkspace: {})
        store.draft = "Independent Home draft"
        #expect(controller.beginDictation(focusPanel: false, expandPanel: false))
        try await waitForJournalFixture { voice.isRecording }
        let callback = try #require(backend.callback); callback(.final("Reviewed voice cafe\u{301}"))
        try await waitForJournalFixture { !voice.isBusy }
        let barrier = OwnedJournalBarrier()
        await core.atNextBoundary(.beforeCommit) { barrier.pause() }
        if outcome == "fault" { await core.injectFault(.afterCommit) }
        controller.sendTranscript()
        let ticket = try #require(controller.pendingSubmission)
        try await waitForJournalFixture { barrier.isEntered }
        callback(.final("Late duplicate final must not replace reviewed text")); controller.sendTranscript()
        #expect(controller.pendingSubmission === ticket && backend.starts == 1)
        #expect(controller.promptText.utf8.elementsEqual("Reviewed voice cafe\u{301}".utf8))
        #expect(store.draft == "Independent Home draft" && turns == 0)
        if outcome == "stop" { store.stop() }
        barrier.release(); await store.waitForConversationTaskToSettle()
        try await waitForJournalFixture { controller.pendingSubmission == nil }
        #expect(store.draft == "Independent Home draft")
        if outcome == "success" {
            #expect(ticket.status == .saved && turns == 1 && controller.promptText.isEmpty)
            #expect(controller.submittedMessageID == ticket.messageID)
        } else {
            #expect(ticket.status == (outcome == "stop" ? .stopped : .failed) && turns == 0)
            #expect(controller.promptText.utf8.elementsEqual("Reviewed voice cafe\u{301}".utf8))
        }
    }
}

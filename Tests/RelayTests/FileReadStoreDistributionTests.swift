import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@Suite(.serialized) @MainActor struct FileReadStoreDistributionTests {
    nonisolated private final class Barrier: @unchecked Sendable {
        private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
        private var started = false, released = false
        var entered: Bool { lock.withLock { started } }
        func pause() { lock.withLock { started = true }; gate.wait() }
        func release() { let signal = lock.withLock { let old = !released; released = true; return old }; if signal { gate.signal() } }
    }
    private func until(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() { try Task.checkCancellation(); try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2)) }
    }
    private func records(_ core: ConversationJournal) async throws -> [JournalRecord] {
        let scope = try await core.scope(); var result: [JournalRecord] = [], cursor: JournalCursor?
        repeat { let page = try await core.page(after: cursor, expectedScope: scope); result += page.records; cursor = page.hasLater ? page.cursor : nil } while cursor != nil
        return result
    }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appending(path: "relay-store-extraction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false); return value
    }

    @Test(arguments: [false, true])
    func actualTransformedReadIsIncludedInSeveralOrdinaryOrRoleTurnsWithoutReconsumingIt(_ multi: Bool) async throws {
        let folder = try root(), file = folder.appending(path: "source.eml"), marker = "OWNED_BODY_" + UUID().uuidString
        try Data("Subject: OWNED\r\nContent-Type: text/plain\r\n\r\n\(marker)\r\n".utf8).write(to: file)
        let history = AssistantConversationHistory(stateURL: folder.appending(path: "state.json")), core = try await history.journalForTesting()
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5))
        let tools = MacTools(); let grants = [ScopeGrant(path: folder.path)]; tools.grants = grants
        var turns = 0, reads = 0, otherCalls = 0, admittedTurns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { input,_,_ in
            turns += 1
            if multi, turns == 1 { return .init(content: #"{"steps":[{"role":"Navigator","title":"Read chosen export"},{"role":"Navigator","title":"Inspect selected folder inventory"}]}"#, toolCalls: []) }
            let readTurn = multi ? 2 : 1
            if turns == readTurn { return .init(content: "", toolCalls: [.init(id: "actual-export-read", name: "read_file", arguments: ["path": .string(file.path)])]) }
            #expect(input.contains { $0.content.contains(marker) }, "The same actual settled read must remain admitted on later model turns.")
            admittedTurns += 1
            if turns == readTurn + 1 {
                return .init(content: "", toolCalls: [.init(id: "independent-read-only", name: multi ? "list_files" : "calculate",
                    arguments: multi ? ["path": .string(folder.path)] : ["expression": .string("6*7")])])
            }
            return .init(content: "The owned selected source was read and checked.", toolCalls: [])
        }, conversationHistory: history, execute: { call in otherCalls += 1; return try await tools.execute(call) },
        executeFileRead: { call, scope in
            reads += 1; return try await tools.execute(call, fileReadScope: scope, fileReadWorker: worker)
        }, fileReadWorker: worker, multiAgent: multi)
        do {
            await store.waitForConversationTaskToSettle(); store.grants = grants
            store.draft = "Read the selected export, inspect the selected inventory, and report current evidence."
            let ticket = try #require(store.send()); #expect(await ticket.waitForAcknowledgment() == .saved)
            await store.waitForConversationTaskToSettle()
            #expect(store.phase == .idle && store.errorMessage == nil)
            #expect(reads == 1 && otherCalls == 1 && admittedTurns == 2)
            let saved = try await records(core)
            let fileIntents = saved.filter { if case let .intent(value) = $0.event.payload { value.toolName == "read_file" } else { false } }
            #expect(fileIntents.count == 1)
            #expect(store.activity.contains { $0.name == "read_file" && $0.detail.contains(marker) })
            store.stop(); await store.waitForConversationTaskToSettle(); await worker.drain(); try await history.close()
            try FileManager.default.removeItem(at: folder)
        } catch {
            store.stop(); await store.waitForConversationTaskToSettle(); await worker.drain(); try? await history.close()
            try? FileManager.default.removeItem(at: folder); throw error
        }
    }

    @Test func anUnboundCustomResultCannotAcquireAReceiptFromItsMatchingSelectedBody() async throws {
        let folder = try root(), file = folder.appending(path: "source.txt"), privateText = "UNBOUND_CUSTOM_BODY_" + UUID().uuidString
        try Data(privateText.utf8).write(to: file)
        let history = AssistantConversationHistory(stateURL: folder.appending(path: "state.json"))
        var turns = 0, customResults = 0
        let store = AssistantStore(persistenceURL: nil, complete: { input,_,_ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [.init(id: "custom-no-capability", name: "read_file", arguments: ["path": .string(file.path)])]) }
            #expect(!input.contains { $0.content.contains(privateText) })
            #expect(!input.flatMap(\.toolCalls).contains { $0.id == "custom-no-capability" })
            return .init(content: "The unbound source body was omitted.", toolCalls: [])
        }, conversationHistory: history, execute: { _ in
            customResults += 1
            return .init(summary: privateText, evidence: "Explicitly synthetic unbound custom executor; no parser receipt.", verified: true)
        })
        do {
            await store.waitForConversationTaskToSettle(); store.grants = [.init(path: folder.path)]
            store.draft = "Inspect the selected file."; store.send(); await store.waitForConversationTaskToSettle()
            #expect(turns == 2 && customResults == 1)
            #expect(store.activity.contains { $0.name == "read_file" && $0.detail.contains("The file result is unavailable for this task.") })
            #expect(!store.activity.contains { $0.detail.contains(privateText) })
            store.stop(); await store.waitForConversationTaskToSettle(); try await history.close(); try FileManager.default.removeItem(at: folder)
        } catch {
            store.stop(); await store.waitForConversationTaskToSettle(); try? await history.close(); try? FileManager.default.removeItem(at: folder); throw error
        }
    }

    @Test func aSecondActualFileResultRetainsItsAcceptedInputDependencyInsteadOfRebindingToOnlyItsOwnBytes() async throws {
        let folder = try root(), a = folder.appending(path: "a.eml"), b = folder.appending(path: "b.eml")
        let markerA = "INCOMING_SOURCE_A_" + UUID().uuidString, markerB = "ACTUAL_SOURCE_B_" + UUID().uuidString
        let eml: (String) -> Data = { Data("Subject: OWNED\r\nContent-Type: text/plain\r\n\r\n\($0)\r\n".utf8) }
        try eml(markerA).write(to: a); try eml(markerB).write(to: b)
        let history = AssistantConversationHistory(stateURL: folder.appending(path: "state.json"))
        let tools = MacTools(), grants = [ScopeGrant(path: folder.path)]; tools.grants = grants
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5))
        var turns = 0, reads = 0
        let store = AssistantStore(persistenceURL: nil, complete: { input,_,_ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [.init(id: "incoming-A", name: "read_file", arguments: ["path": .string(a.path)])]) }
            if turns == 2 {
                #expect(input.contains { $0.content.contains(markerA) })
                return .init(content: "", toolCalls: [.init(id: "derived-B", name: "read_file", arguments: ["path": .string(b.path)])])
            }
            #expect(turns == 3 && !input.contains { $0.content.contains(markerA) || $0.content.contains(markerB) })
            return .init(content: "The dependent private sources are omitted; no read was repeated.", toolCalls: [])
        }, conversationHistory: history, executeFileRead: { call, scope in
            reads += 1
            let result = try await tools.execute(call, fileReadScope: scope, fileReadWorker: worker)
            if call.id == "derived-B" { try eml("CHANGED_SOURCE_A").write(to: a) }
            return result
        }, fileReadWorker: worker)
        do {
            await store.waitForConversationTaskToSettle(); store.grants = grants
            store.draft = "Inspect selected A, then selected B using only current admitted evidence."; store.send()
            await store.waitForConversationTaskToSettle()
            #expect(turns == 3 && reads == 2)
            #expect(store.activity.contains { $0.name == "read_file" && $0.detail.contains(markerA) })
            #expect(!store.activity.contains { $0.detail.contains(markerB) })
            #expect(store.activity.contains { $0.name == "read_file" && $0.detail.contains("The file result is unavailable for this task.") })
            #expect(try Data(contentsOf: b) == eml(markerB))
            store.stop(); await store.waitForConversationTaskToSettle(); await worker.drain(); try await history.close()
            try FileManager.default.removeItem(at: folder)
        } catch {
            store.stop(); await store.waitForConversationTaskToSettle(); await worker.drain(); try? await history.close()
            try? FileManager.default.removeItem(at: folder); throw error
        }
    }

    @Test(arguments: ["drift", "stop"])
    func actualStoreCannotAdmitTheBodyAfterSourceChangeOrStopDuringRealRevalidation(_ change: String) async throws {
        let folder = try root(), file = folder.appending(path: "source.eml"), a = "BODY_A_" + UUID().uuidString, b = "BODY_B_" + UUID().uuidString
        let data: (String) -> Data = { Data("Subject: OWNED\r\nContent-Type: text/plain\r\n\r\n\($0)\r\n".utf8) }
        try data(a).write(to: file)
        let history = AssistantConversationHistory(stateURL: folder.appending(path: "state.json")), core = try await history.journalForTesting()
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5)), barrier = Barrier()
        let tools = MacTools(), grants = [ScopeGrant(path: folder.path)]; tools.grants = grants
        var turns = 0, reads = 0
        let store = AssistantStore(persistenceURL: nil, complete: { input,_,_ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [.init(id: "paused-export-read", name: "read_file", arguments: ["path": .string(file.path)])]) }
            #expect(change == "drift" && !input.contains { $0.content.contains(a) || $0.content.contains(b) })
            return .init(content: "The former source body is unavailable; no action was repeated.", toolCalls: [])
        }, conversationHistory: history, executeFileRead: { call, scope in
            reads += 1
            let value = try await tools.execute(call, fileReadScope: scope, fileReadWorker: worker)
            worker.pauseAfterNextSnapshot { barrier.pause() }
            return value
        }, fileReadWorker: worker)
        do {
            await store.waitForConversationTaskToSettle(); store.grants = grants
            store.draft = "Read the selected export and report admitted evidence."; store.send()
            try await until { barrier.entered }
            if change == "stop" {
                let before = ContinuousClock.now; store.stop()
                #expect(ContinuousClock.now - before < .seconds(1))
                await store.waitForConversationTaskToSettle()
                #expect(worker.activeCount == 1 && turns == 1)
            } else { try data(b).write(to: file) }
            barrier.release(); await store.waitForConversationTaskToSettle(); await worker.drain()
            #expect(reads == 1 && worker.activeCount == 0 && turns == (change == "stop" ? 1 : 2))
            #expect(!store.activity.contains { $0.detail.contains(a) })
            #expect(store.activity.contains { $0.name == "read_file" && $0.detail.contains("The file result is unavailable for this task.") })
            let saved = try await records(core)
            let outcomes = saved.compactMap { record -> JournalToolOutcome? in if case let .result(value) = record.event.payload { value } else { nil } }
            #expect(outcomes.count == 1 && outcomes.first?.kind == .returnedVerified)
            store.stop(); await store.waitForConversationTaskToSettle(); try await history.close(); try FileManager.default.removeItem(at: folder)
        } catch {
            store.stop(); barrier.release(); await store.waitForConversationTaskToSettle(); await worker.drain()
            try? await history.close(); try? FileManager.default.removeItem(at: folder); throw error
        }
    }

    @Test(arguments: [JournalFault.beforeCommit, .afterCommit])
    func storageOnlyRepairPreservesActualReadFactsWithoutPromotingTheUnsettledBodyOrRepeatingIt(_ fault: JournalFault) async throws {
        let folder = try root(), file = folder.appending(path: "source.eml"), marker = "UNSETTLED_PRIVATE_BODY_" + UUID().uuidString
        try Data("Subject: OWNED\r\nContent-Type: text/plain\r\n\r\n\(marker)\r\n".utf8).write(to: file)
        let history = AssistantConversationHistory(stateURL: folder.appending(path: "state.json")), core = try await history.journalForTesting()
        let tools = MacTools(), grants = [ScopeGrant(path: folder.path)]; tools.grants = grants
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5))
        var reads = 0, turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { input,_,_ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [.init(id: "read-before-fault", name: "read_file", arguments: ["path": .string(file.path)])]) }
            #expect(!input.contains { $0.content.contains(marker) })
            return .init(content: "The known read is preserved in Activity. Its former private body is omitted; no read or effect was repeated.", toolCalls: [])
        }, conversationHistory: history, executeFileRead: { call, scope in
            reads += 1
            let result = try await tools.execute(call, fileReadScope: scope, fileReadWorker: worker)
            await core.injectFault(fault); return result
        }, fileReadWorker: worker)
        do {
            await store.waitForConversationTaskToSettle(); store.grants = grants
            store.draft = "Read the selected export once and report current facts."; store.send()
            await store.waitForConversationTaskToSettle()
            #expect(store.phase == .failed && turns == 1 && reads == 1 && store.errorMessage != nil)
            #expect(!store.activity.contains { $0.detail.contains(marker) })
            #expect(store.activity.contains { $0.name == "read_file" && $0.detail.contains("The file result is unavailable for this task.") })
            try await store.retryConversationStorage()
            #expect(reads == 1 && turns == 1)
            store.resume(); await store.waitForConversationTaskToSettle()
            #expect(reads == 1 && turns == 2 && store.errorMessage == nil)
            let saved = try await records(core)
            #expect(saved.filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
            #expect(saved.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
            store.stop(); await store.waitForConversationTaskToSettle(); await worker.drain(); try await history.close(); try FileManager.default.removeItem(at: folder)
        } catch {
            store.stop(); await store.waitForConversationTaskToSettle(); await worker.drain(); try? await history.close()
            try? FileManager.default.removeItem(at: folder); throw error
        }
    }

    @Test(arguments: ["grants", "configuration", "stop"])
    func immutableAcceptedReadScopeSurvivesTheRealIntentAwaitWithoutRenewal(_ change: String) async throws {
        let folder = try root(), file = folder.appending(path: "source.eml")
        try Data("Subject: OWNED\r\nContent-Type: text/plain\r\n\r\nMUST_NOT_READ_AFTER_REVOKE\r\n".utf8).write(to: file)
        let history = AssistantConversationHistory(stateURL: folder.appending(path: "state.json")), core = try await history.journalForTesting()
        let barrier = Barrier(), tools = MacTools(), grants = [ScopeGrant(path: folder.path)]; tools.grants = grants
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5))
        var turns = 0, reads = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _,_,_ in
            turns += 1; #expect(turns == 1)
            await core.atNextBoundary(.afterCommit) { barrier.pause() }
            return .init(content: "", toolCalls: [.init(id: "scope-before-intent", name: "read_file", arguments: ["path": .string(file.path)])])
        }, conversationHistory: history, executeFileRead: { call, scope in
            reads += 1; return try await tools.execute(call, fileReadScope: scope, fileReadWorker: worker)
        }, fileReadWorker: worker)
        do {
            await store.waitForConversationTaskToSettle(); store.grants = grants
            store.draft = "Read the selected export using its originally accepted scope."; store.send()
            try await until { barrier.entered }
            switch change {
            case "grants": store.grants = []
            case "configuration": store.configuration.model = "changed-byte-exact-model-id"
            default: store.stop()
            }
            barrier.release(); await store.waitForConversationTaskToSettle()
            #expect(turns == 1 && reads == 0 && worker.activeCount == 0)
            let saved = try await records(core)
            let intents = saved.compactMap { record -> JournalIntent? in
                if case let .intent(intent) = record.event.payload, intent.toolName == "read_file" { return intent }; return nil
            }
            let intent = try #require(intents.first); #expect(intents.count == 1)
            let outcomes = saved.compactMap { record -> JournalToolOutcome? in
                if case let .result(outcome) = record.event.payload, outcome.invocationID == intent.invocationID { return outcome }; return nil
            }
            #expect(outcomes.count == 1 && outcomes.first?.kind == .notDispatched)
            store.stop(); await store.waitForConversationTaskToSettle(); await worker.drain(); try await history.close()
            try FileManager.default.removeItem(at: folder)
        } catch {
            store.stop(); barrier.release(); await store.waitForConversationTaskToSettle(); await worker.drain()
            try? await history.close(); try? FileManager.default.removeItem(at: folder); throw error
        }
    }
}

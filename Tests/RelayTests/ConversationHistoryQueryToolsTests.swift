import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@MainActor @Suite(.serialized) struct ConversationHistoryQueryToolsTests {
    init() async throws {
        await awaitParitySuiteQuietWindow()
    }
    @MainActor private final class Fixture {
        let root: URL
        var history: AssistantConversationHistory
        let runID = UUID(), scopeID = UUID()
        init() {
            let owned = FileManager.default.temporaryDirectory.appendingPathComponent("relay-history-query-" + UUID().uuidString)
            root = owned; history = AssistantConversationHistory(stateURL: owned.appendingPathComponent("state.json"))
        }
        func seed(_ messages: [(String, JournalVisibleText)]) async throws {
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            try await history.prepare(run)
            let core = try await history.journalForTesting(), scope = try await core.scope()
            let events = try messages.map { kind, text in
                JournalEvent(id: try JournalOpaqueID(UUID().uuidString), taskID: run.taskID, attemptID: run.attemptID,
                    payload: kind == "assistant" ? .assistant(text) : .user(text))
            }
            for start in stride(from: 0, to: events.count, by: 32) {
                _ = try await core.appendBatch(Array(events[start..<min(start + 32, events.count)]), expectedScope: scope)
            }
            try await history.finish(run, outcome: .responseDelivered)
            try await history.close()
            history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json"))
            _ = try await history.journalForTesting()
        }
        func query(_ call: Relay.ToolCall, current: @escaping @MainActor @Sendable () throws -> Void = {}) async throws -> ConversationHistoryQueryTools.Produced {
            try await ConversationHistoryQueryTools.execute(call, history: history, runID: runID, scopeID: scopeID,
                sourceRevision: 0, validateCurrent: current)
        }
        func remove() async { try? await history.close(); try? FileManager.default.removeItem(at: root) }
    }
    private func search(_ query: String, cursor: String? = nil) -> Relay.ToolCall {
        var arguments: [String: JSONValue] = ["query": .string(query)]
        if let cursor { arguments["cursor"] = .string(cursor) }
        return .init(name: "search_history", arguments: arguments)
    }
    private func payload(_ result: ToolResult) throws -> [String: JSONValue] {
        try #require(try JSONDecoder().decode(JSONValue.self, from: Data(result.summary.utf8)).object)
    }
    private func matches(_ result: ToolResult) throws -> [[String: JSONValue]] {
        let value = try payload(result)
        guard case .array(let items) = value["matches"] else { Issue.record("Actual search payload has no matches array."); return [] }
        return try items.map { try #require($0.object) }
    }
    private func read(_ id: String, offset: Int = 0, limit: Int = 8_000) -> Relay.ToolCall {
        .init(name: "read_history", arguments: ["message_id": .string(id), "offset": .number(Double(offset)), "limit": .number(Double(limit))])
    }

    @Test func realSQLiteSearchReadPreservesStableIDsExactBytesAndCharacterPagination() async throws {
        let f = Fixture(), text = "A🧪cafe\u{301} — earlier exact fact: FRIDAY-42"
        do {
            try await f.seed([("user", try .init(text, origin: .user))])
            let found = try await f.query(search("FRIDAY-42"))
            let hit = try #require(try matches(found.result).first), id = try #require(hit["message_id"]?.string)
            let part = try await f.query(read(id, offset: 1, limit: 2)), partValue = try payload(part.result)
            #expect(partValue["text"]?.string == "🧪c" && partValue["next_offset"]?.int == 3)
            let whole = try await f.query(read(id)), wholeValue = try payload(whole.result)
            #expect(Data((try #require(wholeValue["text"]?.string)).utf8) == Data(text.utf8))
            #expect(wholeValue["historical_data"] == .bool(true))
            try await f.history.close()
            f.history = AssistantConversationHistory(stateURL: f.root.appendingPathComponent("state.json"))
            _ = try await f.history.journalForTesting()
            let reopened = try await f.query(read(id))
            #expect(try payload(reopened.result)["message_id"]?.string == id)
            #expect(try payload(reopened.result)["text"]?.string == text)
            await f.remove()
        } catch { await f.remove(); throw error }
    }

    @Test func realSQLiteSourceRequirementsArtifactsOmissionsAndLegacyAreWithheldWithoutMatchingBodies() async throws {
        let f = Fixture(), marker = "WITHHELD_" + UUID().uuidString
        do {
            let requirement = try JournalSourceRequirement(identity: .init("old-selected-source"), revision: Data(repeating: 7, count: 32))
            try await f.seed([("user", try .init("public eligible fact", origin: .user)),
                ("assistant", try .init("public eligible answer", origin: .assistant)),
                ("assistant", try .init(marker + " source", origin: .source)),
                ("user", try .init(marker + " legacy", origin: .legacyUnknown)),
                ("user", try .init(marker + " requirement", origin: .user, sourceRequirements: [requirement])),
                ("user", try .init(marker + " omitted", origin: .user, omissions: [.nativeSnapshot])),
                ("user", try .init(marker + " artifact", origin: .user, artifacts: [try .init(visiblePath: f.root.appendingPathComponent("not-read").path)]))])
            let result = try await f.query(search(marker)), value = try payload(result.result)
            #expect(try matches(result.result).isEmpty)
            #expect(value["withheld_messages"]?.int == 5)
            #expect(!result.result.summary.contains(marker) && !result.result.evidence.contains(f.root.path))
            let core = try await f.history.journalForTesting(), scope = try await core.scope()
            let page = try await core.page(expectedScope: scope)
            let sourceRow = try #require(page.records.first { if case .assistant(let value) = $0.event.payload { value.origin == .source } else { false } })
            let sourceID = "history1:\(scope.storeID.uuidString):\(scope.generation.uuidString):\(sourceRow.sequence)"
            let refused = try await f.query(read(sourceID))
            #expect(try payload(refused.result)["status"] == .string("withheld_by_policy"))
            #expect(!refused.result.summary.contains(marker))
            let eligible = try await f.query(search("public eligible"))
            #expect(try matches(eligible.result).count == 2)
            await f.remove()
        } catch { await f.remove(); throw error }
    }

    @Test func realPagedSearchCapsTwelveHitsAndReportsOmittedMatchesAndContinuation() async throws {
        let f = Fixture()
        do {
            try await f.seed((0..<155).map { ("user", try JournalVisibleText("uniform-prefix fact \($0)", origin: .user)) })
            let first = try await f.query(search("uniform-prefix")), value = try payload(first.result)
            #expect(try matches(first.result).count == 12)
            #expect((value["omitted_matches"]?.int ?? 0) > 0)
            #expect(value["has_more_history"] == .bool(true))
            let cursor = try #require(value["next_cursor"]?.string)
            let next = try await f.query(search("uniform-prefix", cursor: cursor))
            #expect(try matches(next.result).count == 12)
            let ids = Set(try matches(first.result).compactMap { $0["message_id"]?.string })
            #expect(Set(try matches(next.result).compactMap { $0["message_id"]?.string }).isDisjoint(with: ids))
            #expect(first.result.summary.utf8.count <= ConversationHistoryQueryTools.maximumOutputBytes)
            #expect(try payload(next.result)["has_more_history"] == .bool(false))
            await f.remove()
        } catch { await f.remove(); throw error }
    }

    @Test func readByteBudgetInvalidArgumentsAndForeignScopeRefuseWithoutBroadeningPolicy() async throws {
        let f = Fixture(), other = Fixture()
        do {
            let large = "budget " + String(repeating: "\u{0}", count: 10_000) + String(repeating: "🧪", count: 2_000)
            try await f.seed([("user", try .init(large, origin: .user))])
            try await other.seed([("user", try .init("other budget record", origin: .user))])
            let hit = try #require(try matches((try await f.query(search("budget"))).result).first)
            let id = try #require(hit["message_id"]?.string)
            let bounded = try await f.query(read(id, limit: 16_000)), value = try payload(bounded.result)
            #expect(bounded.result.summary.utf8.count <= ConversationHistoryQueryTools.maximumOutputBytes)
            let piece = try #require(value["text"]?.string), next = try #require(value["next_offset"]?.int)
            #expect(Data(piece.utf8) == Data(String(large.prefix(next)).utf8) && next > 0)
            #expect(value["has_more_text"] == .bool(true))
            await #expect(throws: (any Error).self) { _ = try await other.query(self.read(id)) }
            for call in [self.search("x"), self.search(String(repeating: "a", count: 201)),
                Relay.ToolCall(name: "read_history", arguments: ["message_id": .string(id), "offset": .number(0.5)]),
                Relay.ToolCall(name: "read_history", arguments: ["message_id": .string(id), "limit": .bool(true)]),
                Relay.ToolCall(name: "search_history", arguments: ["query": .string("budget"), "path": .string(f.root.path)])] {
                await #expect(throws: (any Error).self) { _ = try await f.query(call) }
            }
            await f.remove(); await other.remove()
        } catch { await f.remove(); await other.remove(); throw error }
    }

    @Test func laterSearchWindowIDsReadDirectlyAcrossReopenAndAllUnicodeTextPages() async throws {
        let f = Fixture(), marker = "LATER-PAGE-FACT-925"
        let exact = marker + " " + String(repeating: "👩🏽‍💻cafe\u{301} العربية\n", count: 25)
        do {
            var messages = try (0..<1_005).map { ("user", try JournalVisibleText("Unrelated saved message \($0)", origin: .user)) }
            messages[925] = ("user", try JournalVisibleText(exact, origin: .user))
            try await f.seed(messages)
            let first = try await f.query(search(marker)), firstValue = try payload(first.result)
            #expect(try matches(first.result).isEmpty)
            #expect(firstValue["examined_records"]?.int == 800 && firstValue["has_more_history"] == .bool(true))
            let cursor = try #require(firstValue["next_cursor"]?.string)
            let later = try await f.query(search(marker, cursor: cursor))
            let hit = try #require(try matches(later.result).first), id = try #require(hit["message_id"]?.string)
            // No search cursor participates in any read, including after restart.
            let initial = try await f.query(read(id, limit: 37)), initialValue = try payload(initial.result)
            #expect(initialValue["record_lookups"]?.int == 1 && initialValue["next_cursor"] == nil)
            try await f.history.close()
            f.history = AssistantConversationHistory(stateURL: f.root.appendingPathComponent("state.json"))
            _ = try await f.history.journalForTesting()
            var offset = 0, combined = "", requests = 0
            while true {
                requests += 1; try #require(requests <= 100)
                let page = try await f.query(read(id, offset: offset, limit: 37)), value = try payload(page.result)
                #expect(value["message_id"]?.string == id && value["offset"]?.int == offset)
                #expect(value["next_cursor"] == nil && value["record_lookups"]?.int == 1)
                combined += try #require(value["text"]?.string)
                let next = try #require(value["next_offset"]?.int)
                if value["has_more_text"] == .bool(false) { #expect(next == exact.count); break }
                try #require(next > offset); offset = next
            }
            #expect(requests > 1 && Data(combined.utf8) == Data(exact.utf8))
            await f.remove()
        } catch { await f.remove(); throw error }
    }

    @Test func actualCoreDirectRecordUsesValidatedOriginalRowAndRefusesWrongScopeOrInvalidSequence() async throws {
        let f = Fixture()
        do {
            try await f.seed([("user", try .init("Original indexed record", origin: .user))])
            let core = try await f.history.journalForTesting(), scope = try await core.scope()
            let page = try await core.page(expectedScope: scope)
            let original = try #require(page.records.first { if case .user = $0.event.payload { true } else { false } })
            let direct = try #require(try await core.record(sequence: original.sequence, expectedScope: scope))
            #expect(direct == original)
            let missing = try await core.record(sequence: Int64.max, expectedScope: scope)
            #expect(missing == nil)
            await #expect(throws: JournalError.invalidEvent) { _ = try await core.record(sequence: 0, expectedScope: scope) }
            let foreign = JournalScope(storeID: scope.storeID, generation: UUID())
            await #expect(throws: JournalError.wrongGeneration) { _ = try await core.record(sequence: original.sequence, expectedScope: foreign) }
            await f.remove()
        } catch { await f.remove(); throw error }
    }

    @Test func actualLeaseProofRefusesStoreRevocationAndActualJournalClear() async throws {
        let f = Fixture(); var current = true
        do {
            try await f.seed([("user", try .init("retained old fact", origin: .user))])
            let result = try await f.query(search("old fact"), current: { guard current else { throw CancellationError() } })
            try await result.sourceProof.validate(); current = false
            await #expect(throws: (any Error).self) { try await result.sourceProof.validator() }
            current = true
            let next = try await f.query(search("old fact"))
            try await f.history.clear()
            #expect(throws: (any Error).self) { try next.validateForPublication() }
            await #expect(throws: (any Error).self) { try await next.sourceProof.validate() }
            await f.remove()
        } catch { await f.remove(); throw error }
    }

    @Test func realStoreCanRecoverAnOldUserFactOutsideModelContextWithoutGenericDispatch() async throws {
        let f = Fixture(), fact = "Old exact fact: parcel BLUE-ORCHID-42 caf\u{e9}", marker = "BLUE-ORCHID-42"
        var turns = 0, genericCalls = 0, receivedExact = false
        var runningStore: AssistantStore?
        do {
            try await f.seed([("user", try .init(fact, origin: .user))])
            let store = AssistantStore(persistenceURL: nil, complete: { input, tools, _ in
                turns += 1
                #expect(tools.contains { $0.name == "search_history" } && tools.contains { $0.name == "read_history" })
                if turns == 1 {
                    #expect(!input.contains { $0.content.contains(fact) })
                    return .init(content: "", toolCalls: [self.search(marker)])
                }
                let tool = try #require(input.last { $0.role == "tool" })
                let feedback = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(tool.content.utf8)).object)
                let body = try #require(feedback["summary"]?.string)
                let value = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)).object)
                if turns == 2 {
                    guard case .array(let hits) = value["matches"] else { throw ConversationHistoryQueryTools.Failure.unavailable }
                    let id = try #require(hits.first?.object?["message_id"]?.string)
                    return .init(content: "", toolCalls: [self.read(id)])
                }
                receivedExact = value["text"]?.string == fact
                return .init(content: "The earlier parcel code was BLUE-ORCHID-42.", toolCalls: [])
            }, conversationHistory: f.history, execute: { _ in genericCalls += 1; throw ConversationHistoryQueryTools.Failure.unavailable })
            runningStore = store
            await store.waitForConversationTaskToSettle()
            store.draft = "Find my earlier parcel code in saved conversation and quote it. Do not take any computer action."
            let ticket = try #require(store.send()); #expect(await ticket.waitForAcknowledgment() == .saved)
            await store.waitForConversationTaskToSettle()
            #expect(turns == 3 && receivedExact && genericCalls == 0 && store.phase == .idle)
            #expect(store.messages.contains { $0.role == "assistant" && $0.text.contains(marker) })
            store.stop(); await store.waitForConversationTaskToSettle(); await f.remove()
        } catch { runningStore?.stop(); await runningStore?.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }

    @Test func realLostResultAcknowledgmentKeepsHistoryBodyClosedAndRepairsStorageOnly() async throws {
        let f = Fixture(), marker = "UNPUBLISHED_QUERY_" + UUID().uuidString
        var turns = 0, genericCalls = 0
        var store: AssistantStore?
        do {
            try await f.seed([("user", try .init(marker, origin: .user))])
            let core = try await f.history.journalForTesting()
            await core.injectResultFault(.afterCommit, forToolName: "search_history")
            let actual = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
                turns += 1; return .init(content: "", toolCalls: [self.search(marker)])
            }, conversationHistory: f.history, execute: { _ in genericCalls += 1; throw ConversationHistoryQueryTools.Failure.unavailable })
            store = actual; await actual.waitForConversationTaskToSettle()
            actual.draft = "Look up an earlier saved fact only."; _ = try #require(actual.send())
            await actual.waitForConversationTaskToSettle()
            #expect(turns == 1 && genericCalls == 0)
            #expect(!actual.activity.contains { $0.name == "search_history" && $0.detail.contains(marker) })
            try await actual.retryConversationStorage()
            #expect(turns == 1 && genericCalls == 0)
            #expect(!actual.activity.contains { $0.name == "search_history" && $0.detail.contains(marker) })
            let scope = try await core.scope(), page = try await core.page(expectedScope: scope)
            #expect(page.records.filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
            #expect(page.records.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
            actual.stop(); await actual.waitForConversationTaskToSettle(); await f.remove()
        } catch { store?.stop(); await store?.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }

    @Test func realResultCommitStopClosesFirstHistoryBodyAndPreservesOneSavedRead() async throws {
        let f = Fixture(), barrier = HistoryQueryCommitBarrier(), marker = "PRIVATE_QUERY_" + UUID().uuidString
        var turns = 0, genericCalls = 0
        var store: AssistantStore?
        do {
            try await f.seed([("user", try .init(marker, origin: .user))])
            let core = try await f.history.journalForTesting()
            await core.atNextResultBoundary(.afterCommit, forToolName: "search_history") { barrier.pause() }
            let actual = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
                turns += 1
                return .init(content: "", toolCalls: [self.search(marker)])
            }, conversationHistory: f.history, execute: { _ in genericCalls += 1; throw ConversationHistoryQueryTools.Failure.unavailable })
            store = actual; await actual.waitForConversationTaskToSettle()
            actual.draft = "Read the earlier saved fact only."; _ = try #require(actual.send())
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !barrier.entered { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(2)) }
            #expect(turns == 1 && !actual.activity.contains { $0.name == "search_history" && $0.detail.contains(marker) })
            actual.stop(); barrier.release(); await actual.waitForConversationTaskToSettle()
            #expect(turns == 1 && genericCalls == 0 && actual.phase == .stopped)
            #expect(!actual.activity.contains { $0.name == "search_history" && $0.detail.contains(marker) })
            let scope = try await core.scope(), page = try await core.page(expectedScope: scope)
            let intents = page.records.compactMap { row -> JournalIntent? in if case .intent(let value) = row.event.payload { value } else { nil } }
            #expect(intents.filter { $0.toolName == "search_history" }.count == 1)
            #expect(page.records.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
            await f.remove()
        } catch { barrier.release(); store?.stop(); await store?.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }
}

nonisolated private final class HistoryQueryCommitBarrier: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var began = false, released = false
    var entered: Bool { lock.withLock { began } }
    func pause() { lock.withLock { began = true }; _ = semaphore.wait(timeout: .now() + 8) }
    func release() { let signal = lock.withLock { let value = !released; released = true; return value }; if signal { semaphore.signal() } }
}

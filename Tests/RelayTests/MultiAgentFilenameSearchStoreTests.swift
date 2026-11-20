import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

/// Actual selected-directory producer, saved receipt and Store role routing.
/// Model replies are inert; no model/native/provider/desktop input is used.
@Suite(.serialized) @MainActor struct MultiAgentFilenameSearchStoreTests {
    @MainActor private final class Fixture {
        let root: URL, selected: URL, file: URL, outside: URL, output: URL
        let marker = "OWNED_FILENAME_" + UUID().uuidString
        let bodyMarker = "UNREAD_FILE_BODY_" + UUID().uuidString
        let outsideMarker = "OUTSIDE_FILENAME_" + UUID().uuidString
        let history: AssistantConversationHistory, worker = FilenameSearchWorker(), tools = MacTools()
        let grantID = UUID()
        init() throws {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("relay-role-query-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            root = try ToolPolicy.canonicalURL(temporary.path)
            selected = root.appendingPathComponent("selected", isDirectory: true)
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
            file = selected.appendingPathComponent(marker + "-needle.txt")
            outside = root.appendingPathComponent(outsideMarker + "-needle.txt")
            output = selected.appendingPathComponent("report.txt")
            try Data(bodyMarker.utf8).write(to: file)
            try Data("OWNED outside bytes".utf8).write(to: outside)
            history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json"))
        }
        func grants(writable: Bool) -> [ScopeGrant] { [.init(id: grantID, path: selected.path, writable: writable)] }
        func query() -> Relay.ToolCall { .init(id: "reused-provider-id", name: "search_files", arguments: ["query": .string("needle")]) }
        func write() -> Relay.ToolCall { .init(id: "reused-provider-id", name: "write_file", arguments: ["path": .string(output.path), "content": .string("Report derived from current filename metadata.")]) }
        func start(_ store: AssistantStore, writable: Bool, objective: String) async throws {
            await store.waitForConversationTaskToSettle()
            let current = grants(writable: writable); tools.grants = current; store.grants = current
            store.draft = objective
            let ticket = try #require(store.send()); #expect(await ticket.waitForAcknowledgment() == .saved)
        }
        func close(_ store: AssistantStore) async {
            store.stop(); await store.waitForConversationTaskToSettle(); await worker.drain()
            try? await history.close(); try? FileManager.default.removeItem(at: root)
        }
    }
    private func records(_ fixture: Fixture) async throws -> [JournalRecord] {
        let core = try await fixture.history.journalForTesting(), scope = try await core.scope()
        return try await core.page(expectedScope: scope).records
    }
    private func checkMetadataOnly(_ input: [ModelMessage], fixture: Fixture) {
        #expect(!input.contains { $0.content.contains(fixture.bodyMarker) || $0.content.contains(fixture.outsideMarker) })
    }

    @Test func actualSelectedQueryReachesPlannerSynthesisThroughTheAcknowledgedStore() async throws {
        let f = try Fixture()
        var plannerTurns = 0, navigatorTurns = 0, queries = 0, effects = 0, receivedCurrentName = false, producedReceipt = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, advertised, _ in
            checkMetadataOnly(input, fixture: f)
            let role = input.first?.content ?? ""
            if role.hasPrefix("ROLE: Planner") {
                plannerTurns += 1; #expect(advertised.isEmpty)
                if plannerTurns == 1 { return .init(content: #"{"steps":[{"id":"names","role":"Navigator","title":"Find current selected filename matches"}]}"#, toolCalls: []) }
                #expect(plannerTurns == 2)
                receivedCurrentName = input.contains { $0.content.contains(f.marker) }
                return .init(content: "Current selected match: " + f.file.path, toolCalls: [])
            }
            #expect(role.hasPrefix("ROLE: Navigator"))
            navigatorTurns += 1
            #expect(advertised.contains { $0.name == "search_files" })
            #expect(!advertised.contains { $0.name == "read_calendar" || $0.name == "write_file" })
            return .init(content: "", toolCalls: [f.query()])
        }, conversationHistory: f.history, execute: { _ in
            effects += 1; throw RelayError.message("This filename-only task has no mutation.")
        }, executeFilenameSearch: { call, scope in
            queries += 1
            let result = try await f.tools.execute(call, filenameSearchScope: scope, filenameSearchWorker: f.worker)
            producedReceipt = result.filenameSearchReceipt != nil
            return result
        }, filenameSearchWorker: f.worker, multiAgent: true)
        do {
            try await f.start(store, writable: false, objective: "Find filename matches for needle in the selected folder and report their exact current paths. Do not read file contents or modify anything.")
            await store.waitForConversationTaskToSettle()
            #expect(plannerTurns == 2 && navigatorTurns == 1 && queries == 1 && effects == 0)
            #expect(producedReceipt && receivedCurrentName)
            #expect(store.phase == .idle && store.errorMessage == nil && store.pendingReview == nil)
            #expect(store.messages.last?.text.contains(f.file.path) == true)
            #expect(store.activity.contains { $0.name == "search_files" && $0.detail.contains(f.marker) })
            #expect(store.grants.count == 1 && store.grants.first?.id == f.grantID && store.grants.first?.writable == false)
            #expect(try Data(contentsOf: f.file) == Data(f.bodyMarker.utf8))
            #expect(!FileManager.default.fileExists(atPath: f.output.path))
            let saved = try await records(f)
            let intents = saved.compactMap { record -> JournalIntent? in if case let .intent(value) = record.event.payload { value } else { nil } }
            let outcomes = saved.compactMap { record -> JournalToolOutcome? in if case let .result(value) = record.event.payload { value } else { nil } }
            #expect(intents.count == 1 && intents.first?.toolName == "search_files")
            #expect(outcomes.count == 1 && outcomes.first?.kind == .returnedVerified)
            await f.close(store)
        } catch { await f.close(store); throw error }
    }

    @Test(arguments: ["source", "grants", "stop"])
    func acceptedExecutorCannotWriteFromQueryMetadataRevokedDuringItsActualIntent(_ change: String) async throws {
        let f = try Fixture(), barrier = RoleQueryIntentBarrier()
        let core = try await f.history.journalForTesting()
        var completions = 0, queries = 0, writes = 0, executorReceivedCurrentName = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, advertised, _ in
            completions += 1; checkMetadataOnly(input, fixture: f)
            let role = input.first?.content ?? ""
            if role.hasPrefix("ROLE: Planner") {
                #expect(completions == 1 && advertised.isEmpty)
                return .init(content: #"{"steps":[{"id":"names","role":"Navigator","title":"Find selected current filenames"},{"id":"report","role":"Executor","title":"Create the requested report from the current match"}]}"#, toolCalls: [])
            }
            if role.hasPrefix("ROLE: Navigator") {
                #expect(advertised.contains { $0.name == "search_files" })
                return .init(content: "", toolCalls: [f.query()])
            }
            #expect(role.hasPrefix("ROLE: Executor") && completions == 3)
            executorReceivedCurrentName = input.contains { $0.content.contains(f.marker) }
            // This is before the accepted Executor proposal enters its actual
            // intent transaction. It cannot target the preceding query result.
            await core.atNextBoundary(.afterCommit) { barrier.pause() }
            return .init(content: "", toolCalls: [f.write()])
        }, conversationHistory: f.history, execute: { call in
            writes += 1; #expect(call.name == "write_file")
            return try await f.tools.execute(call)
        }, executeFilenameSearch: { call, scope in
            queries += 1
            let result = try await f.tools.execute(call, filenameSearchScope: scope, filenameSearchWorker: f.worker)
            #expect(result.filenameSearchReceipt != nil)
            return result
        }, filenameSearchWorker: f.worker, multiAgent: true)
        do {
            try await f.start(store, writable: true, objective: "Find needle filename matches in the selected folder and create the requested text report there using current names.")
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while !barrier.entered { try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2)) }
            #expect(completions == 3 && executorReceivedCurrentName && queries == 1 && writes == 0)
            switch change {
            case "source": try FileManager.default.moveItem(at: f.file, to: f.selected.appendingPathComponent("current-needle.txt"))
            case "grants": store.grants = []
            default: store.stop()
            }
            barrier.release(); await store.waitForConversationTaskToSettle(); await f.worker.drain()
            #expect(completions == 3 && queries == 1 && writes == 0)
            #expect(!FileManager.default.fileExists(atPath: f.output.path))
            #expect(store.phase == (change == "source" ? .failed : .stopped))
            let saved = try await records(f)
            let intents = saved.compactMap { record -> JournalIntent? in if case let .intent(value) = record.event.payload { value } else { nil } }
            let outcomes = saved.compactMap { record -> JournalToolOutcome? in if case let .result(value) = record.event.payload { value } else { nil } }
            #expect(intents.count == 2 && Set(intents.map(\.proposalID)).count == 2)
            #expect(intents.allSatisfy { $0.toolCallID.bytes == Data("reused-provider-id".utf8) })
            #expect(intents.filter { $0.toolName == "search_files" }.count == 1 && intents.filter { $0.toolName == "write_file" }.count == 1)
            #expect(outcomes.filter { $0.kind == .returnedVerified }.count == 1 && outcomes.filter { $0.kind == .notDispatched }.count == 1)
            #expect(try Data(contentsOf: f.outside) == Data("OWNED outside bytes".utf8))
            await f.close(store)
        } catch { barrier.release(); await f.close(store); throw error }
    }
}

nonisolated private final class RoleQueryIntentBarrier: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var began = false, released = false
    var entered: Bool { lock.withLock { began } }
    func pause() { lock.withLock { began = true }; semaphore.wait() }
    func release() { let signal = lock.withLock { let value = !released; released = true; return value }; if signal { semaphore.signal() } }
}

import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

/// Actual metadata producer and SQLite boundaries with synthetic role replies.
/// No model runtime, desktop app, permissions, screenshot or OS input is used.
@Suite(.serialized) @MainActor struct FilenameSearchStorePublicationTests {
    @MainActor private final class Fixture {
        let root: URL, selected: URL, file: URL, output: URL, marker: String
        let history: AssistantConversationHistory, worker = FilenameSearchWorker(), tools = MacTools()
        var grants: [ScopeGrant] { [.init(id: grantID, path: selected.path, writable: true)] }
        private let grantID = UUID()
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-search-publication-" + UUID().uuidString)
            selected = root.appendingPathComponent("selected", isDirectory: true)
            marker = "PRIVATE_NAME_" + UUID().uuidString
            file = selected.appendingPathComponent(marker + "_needle.txt")
            output = selected.appendingPathComponent("derived.txt")
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            try Data("OWNED content is never filename-search input".utf8).write(to: file)
            history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json"))
            tools.grants = grants
        }
        func search() -> Relay.ToolCall { .init(id: "owned-search", name: "search_files", arguments: ["query": .string("needle")]) }
        func write() -> Relay.ToolCall { .init(id: "derived-write", name: "write_file", arguments: ["path": .string(output.path), "content": .string("Derived from a source-bound filename query.")]) }
        func remove() async { await worker.drain(); try? await history.close(); try? FileManager.default.removeItem(at: root) }
    }
    private func start(_ store: AssistantStore, fixture: Fixture,
                       objective: String = "Find names containing needle within the selected folder and report the current matches.") async throws {
        await store.waitForConversationTaskToSettle(); store.grants = fixture.grants
        store.draft = objective
        let ticket = try #require(store.send()); #expect(await ticket.waitForAcknowledgment() == .saved)
    }
    private func records(_ history: AssistantConversationHistory) async throws -> [JournalRecord] {
        let core = try await history.journalForTesting(), scope = try await core.scope()
        return try await core.page(expectedScope: scope).records
    }
    private func wait(_ barrier: SearchPublicationBarrier) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !barrier.entered { try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func actualSelectedQueryReachesTheNextPrivateTurnOnlyAfterItsSavedSourceAdmission() async throws {
        let f = try Fixture(); var turns = 0, queries = 0, receivedActualName = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [f.search()]) }
            receivedActualName = input.contains { $0.content.contains(f.marker) }
            return .init(content: "The selected folder contains the checked matching filename.", toolCalls: [])
        }, conversationHistory: f.history, executeFilenameSearch: { call, scope in
            queries += 1
            return try await f.tools.execute(call, filenameSearchScope: scope, filenameSearchWorker: f.worker)
        }, filenameSearchWorker: f.worker)
        do {
            try await start(store, fixture: f); await store.waitForConversationTaskToSettle()
            #expect(turns == 2 && queries == 1 && receivedActualName)
            #expect(store.activity.contains { $0.name == "search_files" && $0.detail.contains(f.marker) })
            let saved = try await records(f.history)
            #expect(saved.filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
            #expect(saved.filter { if case let .result(value) = $0.event.payload { value.kind == .returnedVerified } else { false } }.count == 1)
            store.stop(); await store.waitForConversationTaskToSettle(); await f.remove()
        } catch { store.stop(); await store.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }

    @Test(arguments: ["source", "grants", "stop", "replacement", "lost_ack_source"])
    func actualResultCommitNeverPublishesItsFirstFilenameAfterRevocationOrSaveFailure(_ change: String) async throws {
        let f = try Fixture(), barrier = SearchPublicationBarrier()
        let core = try await f.history.journalForTesting()
        if change == "lost_ack_source" { await core.injectResultFault(.afterCommit, forToolName: "search_files") }
        // The tool selector binds its invocation in commitIntent, so it must
        // be installed before the accepted proposal enters that transaction.
        await core.atNextResultBoundary(.afterCommit, forToolName: "search_files") { barrier.pause() }
        var turns = 0, queries = 0, laterInputs: [String] = []
        var replacement: ConversationSubmission?
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [f.search()]) }
            let text = input.map(\.content).joined(); laterInputs.append(text)
            #expect(!text.contains(f.marker))
            return .init(content: "The old query fact remains recorded; its former filename metadata was not reused.", toolCalls: [])
        }, conversationHistory: f.history, executeFilenameSearch: { call, scope in
            queries += 1
            let result = try await f.tools.execute(call, filenameSearchScope: scope, filenameSearchWorker: f.worker)
            return result
        }, filenameSearchWorker: f.worker)
        do {
            try await start(store, fixture: f); try await wait(barrier)
            #expect(turns == 1 && queries == 1 && !store.activity.contains { $0.detail.contains(f.marker) })
            switch change {
            case "source", "lost_ack_source": try FileManager.default.moveItem(at: f.file, to: f.selected.appendingPathComponent("CURRENT_needle.txt"))
            case "grants": store.grants = []
            default:
                store.stop()
                if change == "replacement" { store.draft = "Acknowledge this new source-free task."; replacement = store.send() }
            }
            barrier.release(); await store.waitForConversationTaskToSettle(); await f.worker.drain()
            if let replacement {
                #expect(await replacement.waitForAcknowledgment() == .saved)
                await store.waitForConversationTaskToSettle()
                #expect(turns >= 2)
            }
            #expect(queries == 1 && !store.activity.contains { $0.detail.contains(f.marker) })
            #expect(!store.messages.contains { $0.text.contains(f.marker) })
            if change == "lost_ack_source" {
                #expect(store.phase == .failed)
                try await store.retryConversationStorage(); store.resume(); await store.waitForConversationTaskToSettle()
                #expect(queries == 1 && !store.activity.contains { $0.detail.contains(f.marker) })
            }
            #expect(laterInputs.allSatisfy { !$0.contains(f.marker) })
            let saved = try await records(f.history)
            #expect(saved.filter { if case let .intent(value) = $0.event.payload { value.toolName == "search_files" } else { false } }.count == 1)
            #expect(saved.filter { if case let .result(value) = $0.event.payload { value.kind == .returnedVerified } else { false } }.count == 1)
            store.stop(); await store.waitForConversationTaskToSettle(); await f.remove()
        } catch { store.stop(); barrier.release(); await store.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }

    @Test(arguments: ["source", "grants", "stop"])
    func exactQueryProofIsRecheckedAfterTheDerivedWritesDurableIntent(_ change: String) async throws {
        let f = try Fixture(), barrier = SearchPublicationBarrier(), core = try await f.history.journalForTesting()
        var turns = 0, queries = 0, writes = 0, sawActualPrivateSource = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [f.search()]) }
            if turns == 2 {
                sawActualPrivateSource = input.contains { $0.content.contains(f.marker) }
                await core.atNextBoundary(.afterCommit) { barrier.pause() }
                return .init(content: "", toolCalls: [f.write()])
            }
            return .init(content: "The changed query was not used to dispatch the derived file action.", toolCalls: [])
        }, conversationHistory: f.history, execute: { call in
            #expect(call.name == "write_file"); writes += 1; return try await f.tools.execute(call)
        }, executeFilenameSearch: { call, scope in
            queries += 1; return try await f.tools.execute(call, filenameSearchScope: scope, filenameSearchWorker: f.worker)
        }, filenameSearchWorker: f.worker)
        do {
            try await start(store, fixture: f, objective: "Find the selected filenames containing needle, then write derived.txt in that selected folder with a brief description based on the query.")
            try await wait(barrier)
            #expect(sawActualPrivateSource && queries == 1 && writes == 0)
            switch change {
            case "source": try FileManager.default.moveItem(at: f.file, to: f.selected.appendingPathComponent("CURRENT_needle.txt"))
            case "grants": store.grants = []
            default: store.stop()
            }
            barrier.release(); await store.waitForConversationTaskToSettle(); await f.worker.drain()
            #expect(queries == 1 && writes == 0 && !FileManager.default.fileExists(atPath: f.output.path))
            let saved = try await records(f.history)
            let intent = try #require(saved.compactMap { row -> JournalIntent? in
                if case let .intent(value) = row.event.payload, value.toolName == "write_file" { return value }; return nil
            }.first)
            let results = saved.compactMap { row -> JournalToolOutcome? in
                if case let .result(value) = row.event.payload, value.invocationID == intent.invocationID { return value }; return nil
            }
            #expect(results.count == 1 && results.first?.kind == .notDispatched)
            store.stop(); await store.waitForConversationTaskToSettle(); await f.remove()
        } catch { store.stop(); barrier.release(); await store.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }

    @Test func equalTextFromACustomResultCannotAcquireTheActualQuerysSourceAuthority() async throws {
        let f = try Fixture(); var turns = 0, queries = 0
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [f.search()]) }
            #expect(!input.contains { $0.content.contains(f.marker) })
            return .init(content: "No producer-bound result was available.", toolCalls: [])
        }, conversationHistory: f.history, execute: { _ in
            queries += 1; return .init(summary: f.file.path + " [40 bytes]", evidence: "Synthetic equal-looking metadata, not an actual receipt.", verified: true)
        }, filenameSearchWorker: f.worker)
        do {
            try await start(store, fixture: f); await store.waitForConversationTaskToSettle()
            #expect(queries == 1 && turns == 2 && !store.activity.contains { $0.detail.contains(f.marker) })
            #expect(store.activity.contains { $0.detail.contains("The filename result is unavailable for this task.") })
            store.stop(); await store.waitForConversationTaskToSettle(); await f.remove()
        } catch { store.stop(); await store.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }

    @Test(arguments: [false, true])
    func sourceDriftDuringPrivateCompletionRefusesBothReplyPathsBeforeAnyDerivedIntent(_ throwsReply: Bool) async throws {
        let f = try Fixture(); var turns = 0, queries = 0, writes = 0
        let privateError = "UNADMITTED_MODEL_ERROR_" + UUID().uuidString
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [f.search()]) }
            #expect(input.contains { $0.content.contains(f.marker) })
            try FileManager.default.moveItem(at: f.file, to: f.selected.appendingPathComponent("CURRENT_needle.txt"))
            if throwsReply { throw RelayError.message(privateError) }
            return .init(content: "", toolCalls: [f.write()])
        }, conversationHistory: f.history, execute: { call in
            writes += 1; return try await f.tools.execute(call)
        }, executeFilenameSearch: { call, scope in
            queries += 1; return try await f.tools.execute(call, filenameSearchScope: scope, filenameSearchWorker: f.worker)
        }, filenameSearchWorker: f.worker)
        do {
            try await start(store, fixture: f, objective: "Find the selected filename, then write derived.txt based only on that current query.")
            await store.waitForConversationTaskToSettle()
            #expect(turns == 2 && queries == 1 && writes == 0 && !FileManager.default.fileExists(atPath: f.output.path))
            #expect(!(store.errorMessage ?? "").contains(privateError))
            #expect(!store.activity.contains { $0.detail.contains(privateError) })
            let saved = try await records(f.history)
            #expect(!saved.contains { if case let .intent(value) = $0.event.payload { value.toolName == "write_file" } else { false } })
            store.stop(); await store.waitForConversationTaskToSettle(); await f.remove()
        } catch { store.stop(); await store.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }
}

nonisolated private final class SearchPublicationBarrier: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var began = false, released = false
    var entered: Bool { lock.withLock { began } }
    func pause() { lock.withLock { began = true }; _ = semaphore.wait(timeout: .now() + 8) }
    func release() { let signal = lock.withLock { let value = !released; released = true; return value }; if signal { semaphore.signal() } }
}

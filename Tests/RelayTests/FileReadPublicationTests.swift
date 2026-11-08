import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@Suite(.serialized) @MainActor struct FileReadPublicationTests {
    nonisolated private final class Barrier: @unchecked Sendable {
        private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
        private var started = false, released = false
        var entered: Bool { lock.withLock { started } }
        func pause() { lock.withLock { started = true }; gate.wait() }
        func release() { let signal = lock.withLock { let value = !released; released = true; return value }; if signal { gate.signal() } }
    }
    private func wait(_ barrier: Barrier) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !barrier.entered { try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2)) }
    }
    private func ownedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-read-publication-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); return root
    }

    @Test(arguments: ["source", "grants", "stop", "replacement"])
    func actualResultCommitCannotPublishItsFirstPrivateBodyAfterRevocation(_ change: String) async throws {
        let root = try ownedRoot(), file = root.appending(path: "source.eml"), marker = "PRIVATE_FIRST_BODY_" + UUID().uuidString
        let original = Data("Subject: OWNED\r\nContent-Type: text/plain\r\n\r\n\(marker)\r\n".utf8)
        try original.write(to: file)
        let history = AssistantConversationHistory(stateURL: root.appending(path: "state.json")), core = try await history.journalForTesting()
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5)), barrier = Barrier()
        let tools = MacTools(), grants = [ScopeGrant(path: root.path)]; tools.grants = grants
        var turns = 0, reads = 0, laterInputs: [String] = []
        let store = AssistantStore(persistenceURL: nil, complete: { input,_,_ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [.init(id: "result-commit-private-read", name: "read_file", arguments: ["path": .string(file.path)])]) }
            laterInputs.append(input.map(\.content).joined())
            #expect(!input.contains { $0.content.contains(marker) })
            return .init(content: "The current read fact is retained without releasing its former private content.", toolCalls: [])
        }, conversationHistory: history, executeFileRead: { call, scope in
            reads += 1
            let actual = try await tools.execute(call, fileReadScope: scope, fileReadWorker: worker)
            // Intent already committed; this is the actual RESULT transaction.
            await core.atNextBoundary(.afterCommit) { barrier.pause() }
            return actual
        }, fileReadWorker: worker)
        var replacement: ConversationSubmission?
        do {
            await store.waitForConversationTaskToSettle(); store.grants = grants
            store.draft = "Read the selected export once and report admitted evidence."; store.send()
            try await wait(barrier)
            #expect(reads == 1 && turns == 1)
            #expect(!store.activity.contains { $0.detail.contains(marker) }, "The body must not be published while result acknowledgment is pending.")
            switch change {
            case "source": try Data("Subject: OWNED\r\nContent-Type: text/plain\r\n\r\nDIFFERENT_CURRENT_BODY\r\n".utf8).write(to: file)
            case "grants": store.grants = []
            default:
                store.stop()
                if change == "replacement" {
                    store.draft = "Give a source-free acknowledgment for this new task."
                    replacement = store.send()
                }
            }
            barrier.release(); await store.waitForConversationTaskToSettle(); await worker.drain()
            if change == "replacement" {
                let ticket = try #require(replacement)
                #expect(await ticket.waitForAcknowledgment() == .saved)
            }
            #expect(reads == 1 && worker.activeCount == 0)
            #expect(!store.activity.contains { $0.detail.contains(marker) })
            #expect(!store.messages.contains { $0.text.contains(marker) })
            #expect(laterInputs.allSatisfy { !$0.contains(marker) })
            let scope = try await core.scope(), page = try await core.page(expectedScope: scope)
            let intents = page.records.compactMap { record -> JournalIntent? in if case let .intent(value) = record.event.payload { return value }; return nil }
            #expect(intents.count == 1)
            let outcomes = page.records.compactMap { record -> JournalToolOutcome? in if case let .result(value) = record.event.payload { return value }; return nil }
            #expect(outcomes.count == 1 && outcomes.first?.kind == .returnedVerified)
            store.stop(); await store.waitForConversationTaskToSettle(); try await history.close(); try FileManager.default.removeItem(at: root)
        } catch {
            store.stop(); barrier.release(); await store.waitForConversationTaskToSettle(); await worker.drain()
            try? await history.close(); try? FileManager.default.removeItem(at: root); throw error
        }
    }

    @Test func unknownReadErrorTextIsNotSourceAdmittedIntoActivityOrLaterModelHistory() async throws {
        let root = try ownedRoot(), file = root.appending(path: "source.txt"), secretError = "PRIVATE_ERROR_TEXT_" + UUID().uuidString
        try Data("OWNED".utf8).write(to: file)
        let history = AssistantConversationHistory(stateURL: root.appending(path: "state.json"))
        var turns = 0, attempts = 0
        let store = AssistantStore(persistenceURL: nil, complete: { input,_,_ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [.init(id: "private-error-read", name: "read_file", arguments: ["path": .string(file.path)])]) }
            #expect(!input.contains { $0.content.contains(secretError) })
            return .init(content: "The file did not produce an admitted result; no read was repeated.", toolCalls: [])
        }, conversationHistory: history, executeFileRead: { _,_ in
            attempts += 1; throw RelayError.message(secretError)
        })
        do {
            await store.waitForConversationTaskToSettle(); store.grants = [.init(path: root.path)]
            store.draft = "Inspect the selected file."; store.send(); await store.waitForConversationTaskToSettle()
            #expect(attempts == 1 && turns == 2)
            #expect(!store.activity.contains { $0.detail.contains(secretError) })
            #expect(!store.messages.contains { $0.text.contains(secretError) })
            store.stop(); await store.waitForConversationTaskToSettle(); try await history.close(); try FileManager.default.removeItem(at: root)
        } catch {
            store.stop(); await store.waitForConversationTaskToSettle(); try? await history.close(); try? FileManager.default.removeItem(at: root); throw error
        }
    }

    @Test(arguments: ["grants", "context"])
    func actualParserFailureStillChecksItsCurrentScopeAfterTheAwait(_ change: String) async throws {
        let root = try ownedRoot(), file = root.appending(path: "invalid.pdf")
        try Data("OWNED_INVALID_PDF_INPUT".utf8).write(to: file)
        let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        let captured = MultiAgentContinuation.Context(logicalTaskID: run.relation.logicalTaskID,
            configuration: .init(), scopeID: UUID(), sourceRevision: 0)
        var current: MultiAgentContinuation.Context? = captured
        var grants = [ScopeGrant(path: root.path)]
        let call = Relay.ToolCall(id: "failing-parser-current-scope", name: "read_file", arguments: ["path": .string(file.path)])
        let scope = try FileReadExecutionScope(run: run, proposalID: UUID(), call: call, context: captured,
            currentContext: { current }, grants: { grants }, isCurrent: { true })
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5)), barrier = Barrier()
        worker.pauseAfterNextSnapshot { barrier.pause() }
        let pending = Task { @MainActor in try await worker.extract(call: call, grants: grants, scope: scope) }
        do {
            try await wait(barrier)
            if change == "grants" { grants = [] } else { current = nil }
            barrier.release()
            do { _ = try await pending.value; Issue.record("A revoked parser failure returned a result.") }
            catch let failure as FileExtractionWorker.Failure { #expect(failure == .unavailable) }
            await worker.drain(); #expect(worker.activeCount == 0)
            try FileManager.default.removeItem(at: root)
        } catch {
            pending.cancel(); barrier.release(); _ = await pending.result; await worker.drain()
            try? FileManager.default.removeItem(at: root); throw error
        }
    }
}

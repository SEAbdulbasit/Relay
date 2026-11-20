import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@MainActor @Suite(.serialized) struct MainAgentTextCorrectionTests {
    @MainActor private final class Fixture {
        let root: URL, history: AssistantConversationHistory
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5))
        let tools = MacTools()
        var store: AssistantStore?
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "relay-main-correction-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            history = AssistantConversationHistory(stateURL: root.appending(path: "state.json"))
        }
        func close() async {
            let original = store; store = nil
            original?.stop(); await original?.waitForConversationTaskToSettle()
            await worker.drain(); try? await history.close(); try? FileManager.default.removeItem(at: root)
        }
        func records() async throws -> [JournalRecord] {
            let core = try await history.journalForTesting(), scope = try await core.scope()
            var rows: [JournalRecord] = [], cursor: JournalCursor?
            repeat {
                let page = try await core.page(after: cursor, expectedScope: scope)
                rows += page.records; cursor = page.hasLater ? page.cursor : nil
            } while cursor != nil
            return rows
        }
    }
    private func call(_ text: String) -> Relay.ToolCall {
        .init(id: "actual-main-text-correction", name: MainAgentTextCorrectionTool.name, arguments: ["text": .string(text)])
    }
    private func reply(_ corrected: String) throws -> ModelReply {
        .init(content: String(decoding: try JSONEncoder().encode(["corrected_text": corrected]), as: UTF8.self), toolCalls: [])
    }
    private func correctionPayload(_ input: [ModelMessage]) throws -> [String: JSONValue] {
        let tool = try #require(input.last { $0.role == "tool" && $0.toolName == MainAgentTextCorrectionTool.name })
        let feedback = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(tool.content.utf8)).object)
        let summary = try #require(feedback["summary"]?.string)
        return try #require(try JSONDecoder().decode(JSONValue.self, from: Data(summary.utf8)).object)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() { try Task.checkCancellation(); try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2)) }
    }

    @Test(arguments: ["corrected", "unchanged", "canonicalBytes"])
    func actualMainStoreUsesSpecialistAndReturnsExactDataWithoutAnyApplyPath(_ mode: String) async throws {
        let f = try Fixture(), original = " \tcaf\u{e9} teh.\n"
        let corrected = mode == "corrected" ? " \tcaf\u{e9} the.\n" : mode == "canonicalBytes" ? " \tcafe\u{301} teh.\n" : original
        var turns = 0, specialist = 0, generic = 0
        do {
            let store = AssistantStore(persistenceURL: nil, complete: { input, definitions, _ in
                if definitions.isEmpty {
                    specialist += 1
                    #expect(input.count == 2 && input[0].content.contains("corrected_text"))
                    let source = try JSONDecoder().decode([String: String].self, from: Data(try #require(input.last).content.utf8))
                    #expect(Data((try #require(source["selected_text"])).utf8) == Data(original.utf8))
                    return try self.reply(corrected)
                }
                turns += 1
                #expect(definitions.contains { $0.name == MainAgentTextCorrectionTool.name })
                if turns == 1 { return .init(content: "", toolCalls: [self.call(original)]) }
                let payload = try self.correctionPayload(input)
                #expect(Data((try #require(payload["corrected_text"]?.string)).utf8) == Data(corrected.utf8))
                #expect(payload["changed"] == .bool(Data(original.utf8) != Data(corrected.utf8)))
                #expect(payload["applied"] == .bool(false))
                return .init(content: "The requested conservative correction is ready; it was not applied.", toolCalls: [])
            }, conversationHistory: f.history, execute: { _ in generic += 1; throw MainAgentTextCorrectionTool.Failure.unavailable })
            f.store = store; await store.waitForConversationTaskToSettle()
            store.draft = "Please correct the supplied text and return it. Do not edit any app field."
            let ticket = try #require(store.send()); #expect(await ticket.waitForAcknowledgment() == .saved)
            await store.waitForConversationTaskToSettle()
            #expect(turns == 2 && specialist == 1 && generic == 0 && store.phase == .idle)
            #expect(store.quickText.phase == .idle && !store.quickText.canReplace && store.quickText.sourceText.isEmpty)
            let rows = try await f.records()
            let intents = rows.compactMap { row -> JournalIntent? in if case .intent(let value) = row.event.payload { value } else { nil } }
            #expect(intents.count == 1 && intents[0].toolName == MainAgentTextCorrectionTool.name && intents[0].effect == .readOnly)
            #expect(rows.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test(arguments: ["duplicate", "tool", "lineBreak", "partial"])
    func actualSharedServiceRejectsMalformedToolOrStructuralReplies(_ mode: String) async throws {
        let original = "  teh line.\n"
        let bad: ModelReply
        switch mode {
        case "duplicate": bad = .init(content: #"{"corrected_text":"the line.","corrected_text":"other"}"#, toolCalls: [])
        case "tool": bad = .init(content: #"{"corrected_text":"the line."}"#, toolCalls: [.init(name: "open_app", arguments: [:])])
        case "lineBreak": bad = .init(content: #"{"corrected_text":"the\nline."}"#, toolCalls: [])
        default: bad = .init(content: #"{"corrected_text":"the line.""#, toolCalls: [])
        }
        var generations = 0
        await #expect(throws: (any Error).self) {
            _ = try await QuickTextActionSession.correctSuppliedText(original, generate: { _ in generations += 1; return bad })
        }
        #expect(generations == 1)
    }

    @Test(arguments: ["extra", "boolean", "oversize"])
    func invalidMainToolArgumentsNeverReachSpecialistOrGenericExecutor(_ mode: String) async throws {
        let f = try Fixture(); var turns = 0, specialist = 0, generic = 0
        var arguments: [String: JSONValue] = ["text": .string("teh text")]
        if mode == "extra" { arguments["application_id"] = .string("com.apple.TextEdit") }
        if mode == "boolean" { arguments["text"] = .bool(true) }
        if mode == "oversize" { arguments["text"] = .string(String(repeating: "a", count: BoundTextSelection.maximumSelectionBytes + 1)) }
        let invalid = Relay.ToolCall(name: MainAgentTextCorrectionTool.name, arguments: arguments)
        do {
            let store = AssistantStore(persistenceURL: nil, complete: { _, definitions, _ in
                if definitions.isEmpty { specialist += 1; return try self.reply("unexpected") }
                turns += 1
                return turns == 1 ? .init(content: "", toolCalls: [invalid]) : .init(content: "The requested correction arguments were invalid; no field was changed.", toolCalls: [])
            }, conversationHistory: f.history, execute: { _ in generic += 1; throw MainAgentTextCorrectionTool.Failure.unavailable })
            f.store = store; await store.waitForConversationTaskToSettle()
            store.draft = "Correct supplied text only."; _ = try #require(store.send())
            await store.waitForConversationTaskToSettle()
            #expect(specialist == 0 && generic == 0 && !store.quickText.canReplace)
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func realResultAcknowledgmentLossKeepsCorrectionClosedAndRepairsStorageWithoutRegeneration() async throws {
        let f = try Fixture(), marker = "UNPUBLISHED_CORRECTION_" + UUID().uuidString
        var turns = 0, specialist = 0, generic = 0
        do {
            let core = try await f.history.journalForTesting()
            await core.injectResultFault(.afterCommit, forToolName: MainAgentTextCorrectionTool.name)
            let store = AssistantStore(persistenceURL: nil, complete: { _, definitions, _ in
                if definitions.isEmpty { specialist += 1; return try self.reply(marker) }
                turns += 1; return .init(content: "", toolCalls: [self.call("teh supplied sentence with enough room for a conservative bounded answer.")])
            }, conversationHistory: f.history, execute: { _ in generic += 1; throw MainAgentTextCorrectionTool.Failure.unavailable })
            f.store = store; await store.waitForConversationTaskToSettle()
            store.draft = "Return a correction without applying it."; _ = try #require(store.send())
            await store.waitForConversationTaskToSettle()
            #expect(turns == 1 && specialist == 1 && generic == 0)
            #expect(!store.activity.contains { $0.name == MainAgentTextCorrectionTool.name && $0.detail.contains(marker) })
            #expect(!store.messages.contains { $0.text.contains(marker) })
            try await store.retryConversationStorage()
            #expect(turns == 1 && specialist == 1 && generic == 0)
            #expect(!store.activity.contains { $0.name == MainAgentTextCorrectionTool.name && $0.detail.contains(marker) })
            let rows = try await f.records()
            #expect(rows.filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
            #expect(rows.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func actualStopDuringResultCommitPreventsLateCorrectionPublicationOrAnotherModelTurn() async throws {
        let f = try Fixture(), barrier = CommitBarrier(), marker = "STOPPED_CORRECTION_" + UUID().uuidString
        var turns = 0, specialist = 0
        do {
            let core = try await f.history.journalForTesting()
            await core.atNextResultBoundary(.afterCommit, forToolName: MainAgentTextCorrectionTool.name) { barrier.pause() }
            let store = AssistantStore(persistenceURL: nil, complete: { _, definitions, _ in
                if definitions.isEmpty { specialist += 1; return try self.reply(marker) }
                turns += 1; return .init(content: "", toolCalls: [self.call("teh supplied sentence with enough room for a conservative bounded answer.")])
            }, conversationHistory: f.history)
            f.store = store; await store.waitForConversationTaskToSettle()
            store.draft = "Correct supplied text only."; _ = try #require(store.send())
            try await wait { barrier.entered }
            store.stop(); barrier.release(); await store.waitForConversationTaskToSettle()
            #expect(turns == 1 && specialist == 1 && store.phase == .stopped)
            #expect(!store.activity.contains { $0.name == MainAgentTextCorrectionTool.name && $0.detail.contains(marker) })
            #expect(!store.messages.contains { $0.text.contains(marker) })
            let rows = try await f.records()
            #expect(rows.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
            await f.close()
        } catch { barrier.release(); await f.close(); throw error }
    }

    @Test(arguments: ["specialistReply", "resultCommit"])
    func actualSelectedFileDependencyCannotBeReboundToCorrectionAfterSourceDrift(_ stage: String) async throws {
        let f = try Fixture(), barrier = CommitBarrier(), file = f.root.appending(path: "source.txt")
        let original = "teh SOURCE_A_" + UUID().uuidString + ".", corrected = "The CORRECTED_PRIVATE_" + UUID().uuidString + "."
        try Data(original.utf8).write(to: file)
        let grants = [ScopeGrant(path: f.root.path)]; f.tools.grants = grants
        var turns = 0, specialist = 0, reads = 0, generic = 0
        do {
            let core = try await f.history.journalForTesting()
            if stage == "resultCommit" { await core.atNextResultBoundary(.afterCommit, forToolName: MainAgentTextCorrectionTool.name) { barrier.pause() } }
            let store = AssistantStore(persistenceURL: nil, complete: { input, definitions, _ in
                if definitions.isEmpty {
                    specialist += 1
                    if stage == "specialistReply" { try Data("source changed independently".utf8).write(to: file) }
                    return try self.reply(corrected)
                }
                turns += 1
                if turns == 1 { return .init(content: "", toolCalls: [.init(name: "read_file", arguments: ["path": .string(file.path)])]) }
                if turns == 2 {
                    #expect(input.contains { $0.content.contains(original) })
                    return .init(content: "", toolCalls: [self.call(original)])
                }
                #expect(!input.contains { $0.content.contains(original) || $0.content.contains(corrected) })
                #expect(!input.flatMap(\.toolCalls).contains { $0.name == MainAgentTextCorrectionTool.name })
                return .init(content: "The former source changed. No correction was applied.", toolCalls: [])
            }, conversationHistory: f.history, execute: { _ in generic += 1; throw MainAgentTextCorrectionTool.Failure.unavailable },
                executeFileRead: { call, scope in reads += 1; return try await f.tools.execute(call, fileReadScope: scope, fileReadWorker: f.worker) }, fileReadWorker: f.worker)
            f.store = store; await store.waitForConversationTaskToSettle(); store.grants = grants
            store.draft = "Read the selected file and return a correction. Do not edit the file or any app."; _ = try #require(store.send())
            if stage == "resultCommit" { try await wait { barrier.entered }; try Data("source changed independently".utf8).write(to: file); barrier.release() }
            await store.waitForConversationTaskToSettle()
            #expect(turns == 3 && specialist == 1 && reads == 1 && generic == 0)
            #expect(!store.activity.contains { $0.name == MainAgentTextCorrectionTool.name && $0.detail.contains(corrected) })
            #expect(try Data(contentsOf: file) == Data("source changed independently".utf8))
            await f.close()
        } catch { barrier.release(); await f.close(); throw error }
    }

    @Test(arguments: ["stop", "configuration"])
    func actualTaskStopOrReplacementWhileSpecialistAwaitsCannotPublishItsLateReply(_ change: String) async throws {
        let f = try Fixture(), gate = ReplyGate(), marker = "LATE_SPECIALIST_" + UUID().uuidString
        var turns = 0, specialist = 0
        do {
            let store = AssistantStore(persistenceURL: nil, complete: { _, definitions, _ in
                if definitions.isEmpty { specialist += 1; await gate.pause(); return try self.reply(marker) }
                turns += 1; return .init(content: "", toolCalls: [self.call("teh supplied sentence with enough room for a conservative bounded answer.")])
            }, conversationHistory: f.history)
            f.store = store; await store.waitForConversationTaskToSettle()
            store.draft = "Correct text only; do not edit an app."; _ = try #require(store.send())
            try await wait { gate.entered }
            if change == "stop" { store.stop() } else { store.configuration.model = "replacement-model" }
            gate.release(); await store.waitForConversationTaskToSettle()
            #expect(turns == 1 && specialist == 1)
            #expect(!store.activity.contains { $0.detail.contains(marker) } && !store.messages.contains { $0.text.contains(marker) })
            #expect(!store.quickText.canReplace)
            await f.close()
        } catch { gate.release(); await f.close(); throw error }
    }

    @MainActor private final class ReplyGate {
        private(set) var entered = false
        private var waiter: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; await withCheckedContinuation { waiter = $0 } }
        func release() { let old = waiter; waiter = nil; old?.resume() }
    }
    nonisolated private final class CommitBarrier: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var began = false, released = false
        var entered: Bool { lock.withLock { began } }
        func pause() { lock.withLock { began = true }; _ = semaphore.wait(timeout: .now() + 8) }
        func release() { let signal = lock.withLock { let value = !released; released = true; return value }; if signal { semaphore.signal() } }
    }
}

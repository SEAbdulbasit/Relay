import AppKit
import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@MainActor @Suite(.serialized) struct MainAgentSummaryTests {
    private func source() throws -> DocumentSummarySource {
        try .init(kind: .selection, title: "Owned protocol snapshot", application: "Synthetic data",
            text: "The synthetic decision is Thursday.", coverage: "Only owned protocol text; no AX/permission authority.")
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() { try Task.checkCancellation(); try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2)) }
    }
    @MainActor private final class Fixture {
        let root: URL, pdf: URL, history: AssistantConversationHistory
        var store: AssistantStore?
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "relay-main-summary-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            pdf = root.appending(path: "source.pdf")
            history = AssistantConversationHistory(stateURL: root.appending(path: "state.json"))
        }
        func writePDF() async throws {
            try await LocalArtifacts.makePDF(title: "Owned summary", body: "SUMMARY-OWNED-4926: the decision is Thursday.").write(to: pdf)
        }
        func close() async {
            let actual = store; store = nil
            actual?.stop(); await actual?.waitForConversationTaskToSettle()
            await DocumentSummaryCurrentSource.PDFWorker.shared.drain()
            try? await history.close(); try? FileManager.default.removeItem(at: root)
        }
        func records() async throws -> [JournalRecord] {
            let core = try await history.journalForTesting(), scope = try await core.scope()
            var rows: [JournalRecord] = [], cursor: JournalCursor?
            repeat { let page = try await core.page(after: cursor, expectedScope: scope); rows += page.records; cursor = page.hasLater ? page.cursor : nil } while cursor != nil
            return rows
        }
    }

    @Test func actualCoordinatorUsesPerSessionGeneratorAndHoldsBodyUntilExplicitReaderPublication() async throws {
        var global = 0, bound = 0
        let coordinator = DocumentSummaryCoordinator(generate: { _ in global += 1; throw MainAgentSummaryTool.Failure.unavailable })
        let snapshot = try source()
        let session = try coordinator.startForAgent(isSourceAuthorized: { true }, capture: { snapshot }, generate: { messages in
            bound += 1; #expect(messages.last?.content.contains(snapshot.text) == true)
            return .init(content: "The decision is Thursday.", toolCalls: [])
        })
        do {
            let actual = try await coordinator.waitForAgentCompletion(session, validateOwner: {})
            #expect(global == 0 && bound == 1 && session.resultText.isEmpty && session.phase == .generating)
            #expect(try actual.completedText() == "The decision is Thursday.")
            // A genuine generated completion still is not a presentation.
            #expect(!DocumentSummaryPanelController.shared.isPresented(session: session, coordinator: coordinator))
            coordinator.close(id: session.id)
            #expect(throws: (any Error).self) { try actual.validate() }
            #expect(session.source == nil && session.resultText.isEmpty)
        } catch { coordinator.closeAll(); throw error }
    }

    @Test(arguments: ["owner", "closed"])
    func aHeldActualCompletionCannotPublishAfterOwnerRevocationOrReaderClose(_ change: String) async throws {
        let coordinator = DocumentSummaryCoordinator(), snapshot = try source()
        var current = true
        let session = try coordinator.startForAgent(isSourceAuthorized: { current }, capture: { snapshot },
            generate: { _ in .init(content: "An owned summary.", toolCalls: []) })
        do {
            let actual = try await coordinator.waitForAgentCompletion(session, validateOwner: {})
            if change == "owner" { current = false } else { coordinator.close(id: session.id) }
            #expect(throws: (any Error).self) { try actual.publishToReader() }
            #expect(session.resultText.isEmpty)
            #expect(!DocumentSummaryPanelController.shared.isPresented(session: session, coordinator: coordinator))
            coordinator.closeAll()
        } catch { coordinator.closeAll(); throw error }
    }

    @Test func closeDuringPerSessionInferenceCannotInstallALateHeldResultOrCallTheGlobalGenerator() async throws {
        let coordinator = DocumentSummaryCoordinator(), gate = Gate(), snapshot = try source()
        var global = 0
        coordinator.generate = { _ in global += 1; return .init(content: "Wrong generator.", toolCalls: []) }
        let session = try coordinator.startForAgent(isSourceAuthorized: { true }, capture: { snapshot }, generate: { _ in
            await gate.pause(); return .init(content: "Late private output.", toolCalls: [])
        })
        do {
            try await wait { gate.entered }
            coordinator.close(id: session.id); gate.release()
            try await wait { !coordinator.isBusy }
            await #expect(throws: (any Error).self) { _ = try await coordinator.waitForAgentCompletion(session, validateOwner: {}) }
            #expect(global == 0 && session.phase == .closed && session.source == nil && session.resultText.isEmpty)
        } catch { gate.release(); coordinator.closeAll(); throw error }
    }

    @Test func toolArgumentsSelectNoAuthorityAndRejectAmbiguousOrForgedCaptureFields() throws {
        let valid = try MainAgentSummaryTool.decode(.init(name: MainAgentSummaryTool.name,
            arguments: ["application_id": .string("com.apple.TextEdit"), "preference": .string("Brief, in Arabic.")]))
        #expect(valid.applicationID == "com.apple.TextEdit" && valid.pdfPath == nil)
        let invalid: [[String: JSONValue]] = [
            ["application_id": .string("com.apple.TextEdit"), "path": .string("/private/not-selected.pdf")],
            ["native_id": .string("invented"), "screenshot": .string("fabricated")],
            ["path": .bool(true)], ["preference": .string(String(repeating: "x", count: 1_001))]]
        for arguments in invalid {
            #expect(throws: MainAgentSummaryTool.Failure.arguments) { try MainAgentSummaryTool.decode(.init(name: MainAgentSummaryTool.name, arguments: arguments)) }
        }
    }

    @Test func actualEmptyReadScopeRefusesModelApplicationChoiceBeforeAnyCaptureOrSpecialistSend() async throws {
        let f = try Fixture(); var turns = 0, specialist = 0, generic = 0
        do {
            let store = AssistantStore(persistenceURL: nil, complete: { _, definitions, _ in
                if definitions.isEmpty { specialist += 1; return .init(content: "Not admitted.", toolCalls: []) }
                turns += 1
                #expect(definitions.contains { $0.name == MainAgentSummaryTool.name })
                if turns == 1 { return .init(content: "", toolCalls: [.init(name: MainAgentSummaryTool.name, arguments: ["application_id": .string("com.apple.TextEdit")])]) }
                return .init(content: "The original task did not admit that source.", toolCalls: [])
            }, conversationHistory: f.history, execute: { _ in generic += 1; throw MainAgentSummaryTool.Failure.unavailable })
            f.store = store; await store.waitForConversationTaskToSettle()
            store.draft = "Summarize only an admitted source."
            _ = try #require(store.send(nativeReadRestrictions: [])); await store.waitForConversationTaskToSettle()
            #expect(specialist == 0 && generic == 0 && store.summaries.sessions.isEmpty)
            #expect(!store.activity.contains { $0.detail.contains("\"displayed\" : true") })
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test(arguments: ["lostACK", "stop", "rawDrift"])
    func realPDFStoreGenerationCannotPublishBeforeDurableCurrentReaderAdmission(_ mode: String) async throws {
        let f = try Fixture(), barrier = CommitBarrier(), summary = "PRIVATE_SUMMARY_" + UUID().uuidString
        var turns = 0, specialist = 0, generic = 0
        do {
            try await f.writePDF()
            let core = try await f.history.journalForTesting()
            if mode == "lostACK" { await core.injectResultFault(.afterCommit, forToolName: MainAgentSummaryTool.name) }
            if mode == "stop" { await core.atNextResultBoundary(.afterCommit, forToolName: MainAgentSummaryTool.name) { barrier.pause() } }
            let store = AssistantStore(persistenceURL: nil, complete: { input, definitions, _ in
                if definitions.isEmpty {
                    specialist += 1
                    #expect(input.contains { $0.content.contains("SUMMARY-OWNED-4926") })
                    if mode == "rawDrift" {
                        let old = try Relay.LocalStateFile.read(f.pdf, maximumBytes: 10_485_760)
                        try (old + Data("\n% Independent owned raw revision\n".utf8)).write(to: f.pdf)
                    }
                    return .init(content: summary, toolCalls: [])
                }
                turns += 1
                if turns == 1 { return .init(content: "", toolCalls: [.init(name: MainAgentSummaryTool.name, arguments: ["path": .string(f.pdf.path)])]) }
                #expect(!input.contains { $0.content.contains(summary) })
                return .init(content: "The summary was not published; its source or storage needs attention.", toolCalls: [])
            }, conversationHistory: f.history, execute: { _ in generic += 1; throw MainAgentSummaryTool.Failure.unavailable })
            f.store = store; await store.waitForConversationTaskToSettle(); store.grants = [.init(path: f.pdf.path)]
            store.draft = "Summarize the selected PDF in its reader."; _ = try #require(store.send())
            if mode == "stop" { try await wait { barrier.entered }; store.stop(); barrier.release() }
            await store.waitForConversationTaskToSettle()
            #expect(specialist == 1 && generic == 0)
            #expect(!store.activity.contains { $0.detail.contains(summary) } && !store.messages.contains { $0.text.contains(summary) })
            #expect(store.summaries.sessions.isEmpty)
            if mode == "lostACK" {
                #expect(turns == 1); try await store.retryConversationStorage()
                #expect(turns == 1 && specialist == 1 && store.summaries.sessions.isEmpty)
            }
            if mode == "stop" { #expect(turns == 1 && store.phase == .stopped) }
            let rows = try await f.records()
            #expect(rows.filter { if case .intent(let value) = $0.event.payload { value.toolName == MainAgentSummaryTool.name } else { false } }.count == 1)
            #expect(rows.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
            await f.close()
        } catch { barrier.release(); await f.close(); throw error }
    }

    /// Actual owned panel + actual selected PDF + programmatic main tool path;
    /// separate UI lane. No external app, grant prompt or physical click claim.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_MAIN_AGENT_SUMMARY_READER"] == "1"))
    func ownedActualReaderPublishesOnlyAfterSavedResultAndReturnsFreshPDFBody() async throws {
        let app = NSApplication.shared, originalPolicy = app.activationPolicy()
        if originalPolicy == .prohibited { try #require(app.setActivationPolicy(.accessory)) }
        defer {
            let requested = app.activationPolicy() != originalPolicy
            let restored = !requested || app.setActivationPolicy(originalPolicy)
            if !restored || app.activationPolicy() != originalPolicy { Issue.record("Owned summary host policy restoration failed.") }
        }
        let f = try Fixture(), summary = "The actual selected PDF records Thursday as the decision."
        var turns = 0, specialist = 0
        do {
            try await f.writePDF()
            let store = AssistantStore(persistenceURL: nil, complete: { input, definitions, _ in
                if definitions.isEmpty { specialist += 1; return .init(content: summary, toolCalls: []) }
                turns += 1
                if turns == 1 { return .init(content: "", toolCalls: [.init(name: MainAgentSummaryTool.name, arguments: ["path": .string(f.pdf.path)])]) }
                let tool = try #require(input.last { $0.role == "tool" && $0.toolName == MainAgentSummaryTool.name })
                let feedback = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(tool.content.utf8)).object)
                let serializedSummary = try #require(feedback["summary"]?.string)
                let payload = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(serializedSummary.utf8)).object)
                #expect(payload["displayed"] == .bool(true) && payload["body_omitted"] == .bool(false))
                #expect(payload["summary"]?.string == summary)
                return .init(content: "The captured summary is displayed in its reader.", toolCalls: [])
            }, conversationHistory: f.history)
            f.store = store; await store.waitForConversationTaskToSettle(); store.grants = [.init(path: f.pdf.path)]
            store.draft = "Summarize the selected PDF."; _ = try #require(store.send()); await store.waitForConversationTaskToSettle()
            let session = try #require(store.summaries.sessions.first)
            #expect(turns == 2 && specialist == 1 && session.resultText == summary)
            #expect(DocumentSummaryPanelController.shared.isPresented(session: session, coordinator: store.summaries))
            let rows = try await f.records()
            #expect(rows.contains { if case .result(let result) = $0.event.payload { result.kind == .returnedVerified } else { false } })
            await f.close()
        } catch { await f.close(); throw error }
    }

    @MainActor private final class Gate {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { let old = continuation; continuation = nil; old?.resume() }
    }
    nonisolated private final class CommitBarrier: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var began = false, released = false
        var entered: Bool { lock.withLock { began } }
        func pause() { lock.withLock { began = true }; _ = semaphore.wait(timeout: .now() + 8) }
        func release() { let signal = lock.withLock { let value = !released; released = true; return value }; if signal { semaphore.signal() } }
    }
}

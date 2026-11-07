import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Relay

/// Complete local capture/queue/model-boundary flows over inert AX trees. No
/// native app content, OS permission, model, network or clipboard is used.
@MainActor struct NativeDocumentSummaryCoordinatorTests {
    private typealias Subject = SummaryNativeDocumentCapture
    private static let frame = CGRect(x: 0, y: 0, width: 500, height: 500)

    @MainActor private final class Fixture {
        var binding = Subject.Binding(application: .init(processID: 4321,
            launchedAt: Date(timeIntervalSince1970: 1_700_000_000), bundleID: "com.apple.TextEdit",
            bundleURL: URL(fileURLWithPath: "/SYNTHETIC/TextEdit.app")), applicationName: "Synthetic editor",
            window: .init(token: "original-window", title: "Original document", document: "file:///SYNTHETIC/original.txt", frame: frame))
        var mode: Subject.Mode = .document
        var active = true
        var reads = 0
        var tree = Subject.Tree(nodes: [.init(parent: -1, role: "AXWindow", frame: frame),
            .init(parent: 0, role: "AXDocument", frame: frame),
            .init(parent: 1, role: "AXTextArea", value: "The review is Monday at 10:00. Café 🌍.", frame: frame, editable: true)])

        func prepare(isActive: @escaping DocumentSummaryCoordinator.SourceAuthorization = { true }) throws -> DocumentSummaryCoordinator.PreparedCapture {
            let request = try Subject.prepare(mode: mode, binding: binding,
                provider: .init(inspect: { [self] in binding }, read: { [self] in await read() }),
                isActive: { [self] in active && isActive() })
            let kind: DocumentSummarySource.Kind = switch mode { case .document: .nativeDocument; case .conversation: .conversation }
            return .init(kind: kind, isSourceAuthorized: Subject.authorization(for: request), capture: {
                try DocumentSummarySource.native(await Subject.capture(request))
            })
        }
        func read() -> Subject.Tree { reads += 1; return tree }
        func changeWindow() {
            binding = .init(application: binding.application, applicationName: binding.applicationName,
                window: .init(token: "replacement-window", title: "Other document", document: "file:///SYNTHETIC/other.txt", frame: frame))
        }
    }

    @Test func nativeInvocationPinsOriginBeforeDeferredCaptureAndNeverReadsReplacement() async throws {
        let fixture = Fixture()
        var resolutions = 0, generations = 0
        let summaries = DocumentSummaryCoordinator(generate: { _ in
            generations += 1
            return ModelReply(content: "Unexpected generation", toolCalls: [])
        })
        summaries.prepareNativeCapture = { _, isActive in
            resolutions += 1
            return try fixture.prepare(isActive: isActive)
        }
        let session = try summaries.startNative(application: .current)
        #expect(resolutions == 1 && session.phase == .capturing)
        fixture.changeWindow()
        await until { !summaries.isBusy }
        #expect(session.phase == .stopped && fixture.reads == 0 && generations == 0)
        #expect(session.source == nil && session.resultText.isEmpty)
        summaries.closeAll()
    }

    @Test func nativeDocumentReachesOnlyLocalToolFreeSummaryWithCoverageAndExactText() async throws {
        let fixture = Fixture()
        var generations = 0
        let summaries = DocumentSummaryCoordinator(generate: { messages in
            generations += 1
            #expect(messages.count == 2 && messages.allSatisfy { $0.toolCalls.isEmpty })
            let payload = try JSONDecoder().decode([String: String].self,
                from: Data(try #require(messages.last?.content).utf8))
            #expect(payload["source_text"] == "The review is Monday at 10:00. Café 🌍.")
            #expect(payload["capture_coverage"]?.contains("exact originating native document window") == true)
            #expect(!messages.contains { $0.content.contains("/SYNTHETIC/") })
            return ModelReply(content: "The review is Monday at 10:00.", toolCalls: [])
        })
        summaries.prepareNativeCapture = { _, isActive in try fixture.prepare(isActive: isActive) }
        let session = try summaries.startNative(application: .current)
        await until { !summaries.isBusy }
        #expect(generations == 1 && fixture.reads == 1 && session.phase == .ready)
        #expect(session.source?.kind == .nativeDocument && session.source?.location == nil)
        #expect(session.resultText == "The review is Monday at 10:00.")
        summaries.closeAll()
        #expect(session.source == nil && session.resultText.isEmpty)
    }

    @Test func conversationMapsItsWholeMessageCoverageWithoutSidebarOrComposerText() async throws {
        let fixture = Fixture()
        fixture.binding = .init(application: .init(processID: 4321,
            launchedAt: Date(timeIntervalSince1970: 1_700_000_000), bundleID: "com.apple.MobileSMS",
            bundleURL: URL(fileURLWithPath: "/SYNTHETIC/Messages.app")), applicationName: "Synthetic Messages",
            window: .init(token: "message-window", title: "Messages", document: "", frame: Self.frame))
        fixture.mode = .conversation(.messages)
        fixture.tree = .init(nodes: [.init(parent: -1, role: "AXWindow", frame: Self.frame),
            .init(parent: 0, role: "AXGroup", identifier: "TranscriptCollectionView", frame: Self.frame),
            .init(parent: 0, role: "AXButton", identifier: "ConversationTitle", description: "Orchard team",
                frame: CGRect(x: 0, y: 0, width: 500, height: 40)),
            .init(parent: 1, role: "AXGroup", description: "Asha, Review Monday at 10:00, 09:00", frame: CGRect(x: 0, y: 80, width: 500, height: 40)),
            .init(parent: 1, role: "AXGroup", description: "You, Final decision: ship Thursday, 09:05", frame: CGRect(x: 0, y: 700, width: 500, height: 40)),
            .init(parent: 0, role: "AXTextArea", identifier: "MessageEntryView", value: "UNSENT POISON", editable: true),
            .init(parent: 0, role: "AXStaticText", value: "SIDEBAR POISON")])
        let summaries = DocumentSummaryCoordinator(generate: { messages in
            let payload = try JSONDecoder().decode([String: String].self,
                from: Data(try #require(messages.last?.content).utf8))
            #expect(payload["source_text"] == "Asha, Review Monday at 10:00, 09:00\nYou, Final decision: ship Thursday, 09:05")
            #expect(payload["capture_coverage"]?.contains("complete first visible message") == true)
            #expect(messages.allSatisfy { !$0.content.contains("POISON") })
            return ModelReply(content: "Review Monday at 10:00; ship Thursday.", toolCalls: [])
        })
        summaries.prepareNativeCapture = { _, isActive in try fixture.prepare(isActive: isActive) }
        let session = try summaries.startNative(application: .current)
        await until { !summaries.isBusy }
        #expect(session.phase == .ready && session.source?.kind == .conversation)
        #expect(session.source?.title == "Orchard team")
        #expect(session.source?.coverage.contains("Unloaded or local-database history was not read") == true)
        summaries.closeAll()
    }

    @Test func exactOriginRevocationBlocksQueuedInferenceLateResultAndIdleReader() async throws {
        let first = Fixture(), queued = Fixture()
        var prepared = 0, generations = 0
        var finish: CheckedContinuation<ModelReply, Never>?
        let summaries = DocumentSummaryCoordinator(generate: { _ in
            generations += 1
            return await withCheckedContinuation { finish = $0 }
        })
        summaries.prepareNativeCapture = { _, isActive in
            prepared += 1
            return try (prepared == 1 ? first : queued).prepare(isActive: isActive)
        }
        let running = try summaries.startNative(application: .current)
        await until { finish != nil && running.phase == .generating }
        let waiting = try summaries.startNative(application: .current)
        await until { waiting.phase == .queued }
        first.changeWindow(); queued.active = false
        try #require(finish).resume(returning: ModelReply(content: "Late source must disappear.", toolCalls: []))
        await until { !summaries.isBusy }
        #expect(generations == 1 && running.phase == .stopped && waiting.phase == .stopped)
        #expect(running.source == nil && running.resultText.isEmpty && waiting.source == nil)
        let idle = Fixture()
        summaries.prepareNativeCapture = { _, isActive in try idle.prepare(isActive: isActive) }
        summaries.generate = { _ in ModelReply(content: "An independent ready result.", toolCalls: []) }
        let ready = try summaries.startNative(application: .current)
        await until { !summaries.isBusy }
        #expect(ready.phase == .ready)
        idle.changeWindow(); summaries.revalidateSources()
        #expect(ready.phase == .stopped && ready.source == nil && ready.resultText.isEmpty)
        summaries.closeAll()
    }

    @Test func inactiveSessionAndFullCapacityRefuseBeforeNativePreparation() async throws {
        let fixture = Fixture()
        var resolutions = 0
        let summaries = DocumentSummaryCoordinator(generate: { _ in ModelReply(content: "Bounded result.", toolCalls: []) })
        summaries.prepareNativeCapture = { _, isActive in
            resolutions += 1
            return try fixture.prepare(isActive: isActive)
        }
        #expect(throws: Subject.Failure.inactive) { try summaries.startNative(application: .current, isActive: { false }) }
        #expect(resolutions == 0 && fixture.reads == 0 && summaries.sessions.isEmpty)
        for _ in 0..<DocumentSummaryCoordinator.maximumSessions { try summaries.startNative(application: .current) }
        #expect(throws: RelayError.self) { try summaries.startNative(application: .current) }
        #expect(resolutions == DocumentSummaryCoordinator.maximumSessions)
        await until { !summaries.isBusy }
        summaries.closeAll()
    }

    @Test func explicitConversationCannotCaptureGenericDocumentOrEnterInference() throws {
        let fixture = Fixture()
        let summaries = DocumentSummaryCoordinator(generate: { _ in
            Issue.record("A native document cannot satisfy an explicit conversation request.")
            return ModelReply(content: "Unexpected result", toolCalls: [])
        })
        summaries.prepareNativeCapture = { _, isActive in try fixture.prepare(isActive: isActive) }
        #expect(throws: Subject.Failure.unsupportedProfile) {
            try summaries.startNative(application: .current, requiredKind: .conversation)
        }
        #expect(summaries.sessions.isEmpty && fixture.reads == 0 && !summaries.isBusy)
    }

    @Test func metadataOnlyPDFShowsExplicitSafeFallbackWithoutReadingAFileOrCallingModel() async throws {
        let fixture = Fixture()
        fixture.binding = .init(application: fixture.binding.application, applicationName: "Synthetic Preview",
            window: .init(token: "pdf-window", title: "Unopened PDF", document: "file:///SYNTHETIC/NEVER-OPENED.pdf", frame: Self.frame))
        fixture.tree = .init(nodes: [])
        var generations = 0
        let summaries = DocumentSummaryCoordinator(generate: { _ in
            generations += 1
            return ModelReply(content: "Unexpected result", toolCalls: [])
        })
        summaries.prepareNativeCapture = { _, isActive in try fixture.prepare(isActive: isActive) }
        let session = try summaries.startNative(application: .current)
        await until { !summaries.isBusy }
        #expect(generations == 0 && fixture.reads == 1 && session.phase == .failed)
        #expect(session.errorMessage?.contains("Choose that PDF explicitly") == true)
        #expect(session.errorMessage?.contains("/SYNTHETIC/") == false)
        #expect(session.source == nil && session.resultText.isEmpty)
        summaries.closeAll()
    }

    private func until(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition(), "Synthetic native summary did not settle.")
    }
}

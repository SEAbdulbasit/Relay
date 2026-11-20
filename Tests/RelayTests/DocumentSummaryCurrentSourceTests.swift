import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Relay

@MainActor struct DocumentSummaryCurrentSourceTests {
    private typealias Subject = DocumentSummaryCurrentSource
    private final class Owner {
        var current = true
        var grants: [ScopeGrant]
        init(_ path: String) { grants = [ScopeGrant(path: path)] }
        func validate() throws { if !current { throw Subject.Failure.changedSource } }
    }
    private nonisolated final class ReadPause: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting = false
        private let gate = DispatchSemaphore(value: 0)
        var entered: Bool { lock.withLock { waiting } }
        func hold() { lock.withLock { waiting = true }; gate.wait() }
        func release() { gate.signal() }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "relay-summary-current-Caf\u{00e9}-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func actualPDF(_ url: URL) async throws {
        try await LocalArtifacts.makePDF(title: "Owned source", body: "SUMMARY-SOURCE-5837: the exact decision is Thursday.").write(to: url)
    }
    private func prepare(_ url: URL, owner: Owner, worker: Subject.PDFWorker) throws -> Subject {
        try Subject.preparePDF(path: url.path, currentGrants: { owner.grants },
            validateCurrent: { try owner.validate() }, worker: worker)
    }
    private func waitForPause(_ pause: ReadPause) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !pause.entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(pause.entered, "The actual owned PDF snapshot must reach its physical pause.")
    }

    @Test func actualPDFCaptureBindsParserInputAndRejectsChangedRawBytesEvenWithSameTextLayer() async throws {
        let root = try directory(), worker = Subject.PDFWorker()
        let file = root.appending(path: "source.pdf")
        do {
            try await actualPDF(file)
            let owner = Owner(file.path), source = try prepare(file, owner: owner, worker: worker)
            let captured = try await source.capture()
            #expect(captured.source.kind == .pdf && captured.source.text.contains("SUMMARY-SOURCE-5837"))
            #expect(captured.source.coverage.contains("1 of 1 PDF pages"))
            let proof = try #require(try captured.sourceProof(runID: UUID(), scopeID: UUID(), sourceRevision: 1, inputProof: nil))
            try await proof.validate(); try await proof.validator()
            try captured.validateSnapshotScope()
            let original = try Relay.LocalStateFile.read(file, maximumBytes: 10_485_760)
            try (original + Data("\n% Owned raw-byte-only revision\n".utf8)).write(to: file)
            // PDF text still extracts identically; the actual raw source version does not.
            let after = try await DocumentSummaryCapture.extractPDF(data: Relay.LocalStateFile.read(file, maximumBytes: 10_485_760),
                title: file.lastPathComponent, path: file.path)
            #expect(after.text.utf8.elementsEqual(captured.source.text.utf8))
            await #expect(throws: Subject.Failure.changedSource) { try await proof.validate() }
            #expect(throws: Subject.Failure.changedSource) { try captured.validateSnapshotScope() }
            await worker.drain(); #expect(worker.activeCount == 0)
        } catch {
            await worker.drain(); try? FileManager.default.removeItem(at: root); throw error
        }
        try FileManager.default.removeItem(at: root)
    }

    @Test(arguments: ["grantIdentity", "grantRemoval", "grantUnicode", "stop"])
    func actualPDFCapturedAuthorizationRefusesChangedGrantOrOwner(_ change: String) async throws {
        let root = try directory(), worker = Subject.PDFWorker(), file = root.appending(path: "source.pdf")
        do {
            try await actualPDF(file)
            let owner = Owner(file.path), source = try prepare(file, owner: owner, worker: worker)
            let captured = try await source.capture()
            let proof = try #require(try captured.sourceProof(runID: UUID(), scopeID: UUID(), sourceRevision: 2, inputProof: nil))
            let validator = captured.snapshotScopeValidator
            if change == "grantIdentity" { owner.grants = [ScopeGrant(path: file.path)] }
            else if change == "grantRemoval" { owner.grants = [] }
            else if change == "grantUnicode" {
                let originalPath = owner.grants[0].path
                let composed = originalPath.precomposedStringWithCanonicalMapping
                let decomposed = originalPath.decomposedStringWithCanonicalMapping
                try #require(!composed.utf8.elementsEqual(decomposed.utf8))
                owner.grants[0].path = originalPath.utf8.elementsEqual(composed.utf8) ? decomposed : composed
                #expect(owner.grants[0].path == file.path) // Swift canonical equality is insufficient.
                #expect(!owner.grants[0].path.utf8.elementsEqual(file.path.utf8))
            }
            else { owner.current = false }
            #expect(throws: Subject.Failure.changedSource) { try validator() }
            await #expect(throws: Subject.Failure.changedSource) { try await proof.validator() }
            await worker.drain(); #expect(worker.activeCount == 0)
        } catch { await worker.drain(); try? FileManager.default.removeItem(at: root); throw error }
        try FileManager.default.removeItem(at: root)
    }

    @Test func pinnedPDFRefusesReplacementAndSymlinkRetargetBeforeReadingAnotherSource() async throws {
        let root = try directory(), worker = Subject.PDFWorker()
        let file = root.appending(path: "source.pdf"), other = root.appending(path: "other.pdf")
        do {
            try await actualPDF(file); try await actualPDF(other)
            let owner = Owner(root.path), source = try prepare(file, owner: owner, worker: worker)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            await #expect(throws: Subject.Failure.changedSource) { try await source.capture() }
            #expect(worker.activeCount == 0)
        } catch { await worker.drain(); try? FileManager.default.removeItem(at: root); throw error }
        try FileManager.default.removeItem(at: root)
    }

    @Test func cancellationReleasesWaiterButKeepsActualPhysicalPDFSlotUntilKernelFinishes() async throws {
        let root = try directory(), worker = Subject.PDFWorker(), pause = ReadPause()
        let file = root.appending(path: "source.pdf")
        var pending: Task<Subject.Captured, any Error>?
        do {
            try await actualPDF(file)
            let owner = Owner(file.path), source = try prepare(file, owner: owner, worker: worker)
            worker.pauseAfterNextSnapshot { pause.hold() }
            let task = Task { try await source.capture() }; pending = task
            try await waitForPause(pause)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(worker.activeCount == 1)
            await #expect(throws: Subject.Failure.busy) { try await source.capture() }
            pause.release(); await worker.drain(); pending = nil
            #expect(worker.activeCount == 0)
            let fresh = try await source.capture()
            #expect(fresh.source.text.contains("SUMMARY-SOURCE-5837"))
        } catch {
            pending?.cancel(); pause.release(); _ = await pending?.result
            await worker.drain(); try? FileManager.default.removeItem(at: root); throw error
        }
        await worker.drain(); try FileManager.default.removeItem(at: root)
    }

    @Test func changedOwnerDuringActualProofReadCannotReachPrivateSendAndWorkerDrains() async throws {
        let root = try directory(), worker = Subject.PDFWorker(), pause = ReadPause(), file = root.appending(path: "source.pdf")
        var pending: Task<Void, any Error>?
        do {
            try await actualPDF(file)
            let owner = Owner(file.path), source = try prepare(file, owner: owner, worker: worker)
            let captured = try await source.capture()
            let proof = try #require(try captured.sourceProof(runID: UUID(), scopeID: UUID(), sourceRevision: 3, inputProof: nil))
            var privateSends = 0
            worker.pauseAfterNextSnapshot { pause.hold() }
            let task = Task { try await proof.validate(); privateSends += 1 }; pending = task
            try await waitForPause(pause)
            owner.current = false; pause.release()
            await #expect(throws: Subject.Failure.changedSource) { try await task.value }
            #expect(privateSends == 0)
            pending = nil; await worker.drain(); #expect(worker.activeCount == 0)
        } catch {
            pending?.cancel(); pause.release(); _ = await pending?.result
            await worker.drain(); try? FileManager.default.removeItem(at: root); throw error
        }
        try FileManager.default.removeItem(at: root)
    }

    @Test func actualPDFProofIsFlatStablePerRunAndFinalOwnerRevocationCannotHideBehindLaterInputAwait() async throws {
        let root = try directory(), worker = Subject.PDFWorker(), file = root.appending(path: "source.pdf")
        do {
            try await actualPDF(file)
            let owner = Owner(file.path), source = try prepare(file, owner: owner, worker: worker)
            let first = try await source.capture(), second = try await source.capture()
            let run = UUID(), scope = UUID()
            let a = try #require(try first.sourceProof(runID: run, scopeID: scope, sourceRevision: 4, inputProof: nil))
            let b = try #require(try second.sourceProof(runID: run, scopeID: scope, sourceRevision: 4, inputProof: nil))
            let same = try #require(try ModelInputSourceProof.merging([a, b]))
            #expect(same.dependencyCount == 1)
            try await same.validate()
            let otherRun = try #require(try second.sourceProof(runID: UUID(), scopeID: scope, sourceRevision: 4, inputProof: nil))
            #expect(try ModelInputSourceProof.merging([a, otherRun])?.dependencyCount == 2)
            let later = ModelInputSourceProof.source(identity: .init(owner: UUID(), sourceID: Data([1]), purpose: "owned-test-input")) {
                await Task.yield(); owner.current = false
            }
            let composite = try #require(try ModelInputSourceProof.merging([a, later]))
            await #expect(throws: Subject.Failure.changedSource) { try await composite.validate() }
            owner.current = true
            await #expect(throws: Subject.Failure.changedSource) { try await composite.validator() }
            await worker.drain()
        } catch { await worker.drain(); try? FileManager.default.removeItem(at: root); throw error }
        try FileManager.default.removeItem(at: root)
    }

    @Test func equalContentAtDifferentOwnedPathsDoesNotMintTheSameSourceIdentity() async throws {
        let root = try directory(), worker = Subject.PDFWorker()
        let first = root.appending(path: "first.pdf"), second = root.appending(path: "second.pdf")
        do {
            try await actualPDF(first)
            try Relay.LocalStateFile.read(first, maximumBytes: 10_485_760).write(to: second)
            let owner = Owner(root.path)
            let a = try prepare(first, owner: owner, worker: worker), again = try prepare(first, owner: owner, worker: worker)
            let b = try prepare(second, owner: owner, worker: worker)
            #expect(a.canReuseForAnotherCapture && again.canReuseForAnotherCapture && b.canReuseForAnotherCapture)
            #expect(a.sharesOriginalSource(with: again) && a.sharesOriginalSource(with: a))
            #expect(!a.sharesOriginalSource(with: b))
        } catch { await worker.drain(); try? FileManager.default.removeItem(at: root); throw error }
        try FileManager.default.removeItem(at: root)
    }

    @Test func genericAndFrozenNativeProvidersCannotBecomeActualFreshBodyCapabilities() throws {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let binding = SummaryNativeDocumentCapture.Binding(application: .init(processID: 4321,
            launchedAt: Date(timeIntervalSince1970: 1_700_000_000), bundleID: "com.apple.TextEdit",
            bundleURL: URL(fileURLWithPath: "/SYNTHETIC/TextEdit.app")), applicationName: "Synthetic",
            window: .init(token: "not-an-actual-window", title: "Source", document: "", frame: frame))
        let tree = SummaryNativeDocumentCapture.Tree(nodes: [.init(parent: -1, role: "AXWindow", frame: frame)])
        let generic = try SummaryNativeDocumentCapture.prepare(mode: .document, binding: binding,
            provider: .init(inspect: { binding }, read: { tree }), isActive: { true })
        let frozen = try SummaryNativeDocumentCapture.prepareFrozen(mode: .document, binding: binding,
            tree: tree, inspect: { binding }, isActive: { true })
        #expect(SummaryNativeDocumentCapture.retainedSource(for: generic) == nil)
        #expect(SummaryNativeDocumentCapture.retainedSource(for: frozen) == nil)
    }

    @Test func actualUsedBodyDigestUsesExactUTF8AndCoverageButNotCaptureClock() throws {
        func source(text: String, coverage: String = "Whole bounded source", truncated: Bool = false,
                    at: TimeInterval = 1) throws -> DocumentSummarySource {
            try .init(kind: .nativeDocument, title: "Source", application: "Owned", text: text,
                coverage: coverage, truncated: truncated, capturedAt: Date(timeIntervalSince1970: at))
        }
        let nfc = try source(text: "Caf\u{00e9}"), same = try source(text: "Caf\u{00e9}", at: 2)
        #expect(Subject.bodyDigest(nfc) == Subject.bodyDigest(same))
        #expect(try Subject.bodyDigest(source(text: "Cafe\u{0301}")) != Subject.bodyDigest(nfc))
        #expect(try Subject.bodyDigest(source(text: nfc.text, coverage: "Partial source")) != Subject.bodyDigest(nfc))
        #expect(try Subject.bodyDigest(source(text: nfc.text, truncated: true)) != Subject.bodyDigest(nfc))
    }
}

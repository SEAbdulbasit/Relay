import AppKit
import ApplicationServices
import Foundation
import ImageIO
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor
struct TargetBoundNativeObservationTests {
    @Test func validatesNativePathBundlePIDAndQuotedWindowHeader() throws {
        let header = try TargetBoundNativeObservation.parseHeader(TargetObservationFixture.text())
        #expect(header.path == "/Applications/Synthetic Fixture.app")
        #expect(header.bundleID == "test.synthetic.fixture" && header.processID == 4_242)
        #expect(header.windowTitle == "Synthetic \"window\" — café")
        for text in ["App=/Applications/Synthetic Fixture.app", TargetObservationFixture.text().replacingOccurrences(of: "pid 4242", with: "pid -1"),
                     TargetObservationFixture.text().replacingOccurrences(of: "<app_state>", with: "<different_state>"),
                     TargetObservationFixture.text().replacingOccurrences(of: "Window: \"Synthetic \"window\" — café\"", with: "Window: \"") ] {
            #expect(throws: TargetBoundNativeObservation.Failure.malformedHeader) { try TargetBoundNativeObservation.parseHeader(text) }
        }
    }

    @Test func publishesScopedTextAndMemoryOnlyImageWithNamespacedNativeIndices() async throws {
        let fixture = TargetObservationFixture()
        fixture.image = try image(width: 4, height: 3)
        let adapter = fixture.adapter()
        let snapshot = try await adapter.observe(adapter.prepare(fixture.preparation()))
        #expect(snapshot.images.count == 1 && snapshot.images.first?.width == 4 && snapshot.images.first?.height == 3)
        #expect(snapshot.references.count == 3 && snapshot.references.allSatisfy { $0.hasPrefix("native:") })
        #expect(snapshot.text.contains("[\(snapshot.references[1])] text field (settable)"))
        #expect(!snapshot.text.contains("\n\t1 text field"))
        #expect(snapshot.text.contains("The focused UI element is [\(snapshot.references[1])]") )
        #expect(adapter.isCurrent(snapshot) && adapter.latest?.id == snapshot.id)
        #expect(fixture.captures == ["/Applications/Synthetic Fixture.app"])
        adapter.stop(); await adapter.drain()
        #expect(!adapter.isCurrent(snapshot) && adapter.latest == nil)
    }

    @Test func newObservationInvalidatesPreviousSnapshotAndConsumedPreparedRequest() async throws {
        let fixture = TargetObservationFixture()
        let adapter = fixture.adapter()
        let request = try adapter.prepare(fixture.preparation())
        let first = try await adapter.observe(request)
        await #expect(throws: TargetBoundNativeObservation.Failure.staleRequest) { try await adapter.observe(request) }
        let second = try await adapter.observe(adapter.prepare(fixture.preparation()))
        #expect(!adapter.isCurrent(first) && adapter.isCurrent(second))
        #expect(Set(first.references).isDisjoint(with: Set(second.references)))
        adapter.stop(); await adapter.drain()
    }

    @Test(arguments: ["pid", "path", "bundle", "window"])
    func wrongNativeProvenanceCannotPublishAnyTextOrImage(field: String) async throws {
        let fixture = TargetObservationFixture()
        switch field {
        case "pid": fixture.text = fixture.text.replacingOccurrences(of: "pid 4242", with: "pid 4243")
        case "path": fixture.text = fixture.text.replacingOccurrences(of: "/Applications/Synthetic Fixture.app", with: "/Applications/Another Copy.app")
        case "bundle": fixture.text = fixture.text.replacingOccurrences(of: "test.synthetic.fixture", with: "test.other.fixture")
        default: fixture.text = fixture.text.replacingOccurrences(of: "Synthetic \"window\" — café", with: "Other profile window")
        }
        fixture.image = try image(width: 2, height: 2)
        let adapter = fixture.adapter()
        await #expect(throws: (any Error).self) { try await adapter.observe(adapter.prepare(fixture.preparation())) }
        #expect(adapter.latest == nil && fixture.captures.count == 1)
        // A refused read does not leave the adapter permanently busy.
        fixture.text = TargetObservationFixture.text()
        _ = try await adapter.observe(adapter.prepare(fixture.preparation()))
        adapter.stop(); await adapter.drain()
    }

    @Test func ambiguousProcessAndDuplicateWindowTitlesRefuseBeforeNativeCapture() async throws {
        for cause in [TargetBoundNativeObservation.Failure.ambiguousApplication, .wrongWindow] {
            let fixture = TargetObservationFixture()
            let adapter = fixture.adapter()
            fixture.validationError = cause
            #expect(throws: cause) { try adapter.prepare(fixture.preparation()) }
            #expect(fixture.captures.isEmpty)
            adapter.stop(); await adapter.drain()
        }
    }

    @Test(arguments: ["process", "window", "document", "tab", "url"])
    func targetDriftWhileNativeCaptureIsPendingCannotPublish(field: String) async throws {
        let fixture = TargetObservationFixture()
        fixture.paused = true
        let adapter = fixture.adapter()
        let request = try adapter.prepare(fixture.preparation())
        let operation = Task { try await adapter.observe(request) }
        try await waitUntil { fixture.captures.count == 1 }
        switch field {
        case "process": fixture.processGeneration += 1
        case "window": fixture.windowGeneration += 1
        case "document": fixture.documentGeneration += 1
        case "tab": fixture.tabGeneration += 1
        default: fixture.url = "https://synthetic.invalid/other-profile"
        }
        fixture.release()
        await #expect(throws: TargetBoundNativeObservation.Failure.changedTarget) { try await operation.value }
        #expect(adapter.latest == nil)
        adapter.stop(); await adapter.drain()
    }

    @Test func metadataDriftInvalidatesPublishedSnapshotWhenAConsumerChecksIt() async throws {
        let fixture = TargetObservationFixture()
        let adapter = fixture.adapter()
        let snapshot = try await adapter.observe(adapter.prepare(fixture.preparation()))
        fixture.tabGeneration += 1
        #expect(!adapter.isCurrent(snapshot) && adapter.latest == nil)
        adapter.stop(); await adapter.drain()
    }

    @Test func inactiveSessionCancelsCaptureAndDiscardsALateUncooperativeResult() async throws {
        let fixture = TargetObservationFixture()
        fixture.paused = true
        let adapter = fixture.adapter()
        let operation = Task { try await adapter.observe(adapter.prepare(fixture.preparation())) }
        try await waitUntil { fixture.captures.count == 1 }
        adapter.setSessionActive(false)
        await adapter.drain()
        fixture.release()
        await #expect(throws: TargetBoundNativeObservation.Failure.inactiveSession) { try await operation.value }
        #expect(adapter.latest == nil && fixture.closeCount == 1)
        adapter.setSessionActive(true)
        #expect(throws: TargetBoundNativeObservation.Failure.stopped) { try adapter.prepare(fixture.preparation()) }
        #expect(fixture.captures.count == 1)
    }

    @Test func inactiveSessionClosureBlocksCaptureBeforeAnyOSOrNativeRequest() {
        let fixture = TargetObservationFixture()
        let adapter = fixture.adapter()
        fixture.active = false
        #expect(throws: TargetBoundNativeObservation.Failure.inactiveSession) { try adapter.prepare(fixture.preparation()) }
        #expect(fixture.captures.isEmpty && adapter.latest == nil)
    }

    @Test func reconnectRotatesReferenceNamespaceAndDoesNotCaptureOnItsOwn() async throws {
        let firstBackend = TargetObservationFixture()
        let adapter = firstBackend.adapter()
        let first = try await adapter.observe(adapter.prepare(firstBackend.preparation()))
        let next = TargetObservationFixture()
        try await adapter.reconnect(backend: next.backend)
        #expect(!adapter.isCurrent(first) && next.captures.isEmpty && firstBackend.closeCount == 1)
        let second = try await adapter.observe(adapter.prepare(next.preparation()))
        #expect(Set(first.references).isDisjoint(with: Set(second.references)))
        adapter.stop(); await adapter.drain()
    }

    @Test func malformedAndOversizedImagesLeaveUsefulScopedAccessibilityTextAvailable() async throws {
        for value in [JSONValue.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string("invalid base64")]),
                      try image(width: 8_193, height: 1)] {
            let fixture = TargetObservationFixture()
            fixture.image = value
            let adapter = fixture.adapter()
            let snapshot = try await adapter.observe(adapter.prepare(fixture.preparation()))
            #expect(snapshot.images.isEmpty && snapshot.imageCoverage != nil && !snapshot.references.isEmpty)
            #expect(adapter.isCurrent(snapshot))
            adapter.stop(); await adapter.drain()
        }
    }

    @Test func headerOnlyReceiptWithInvalidImageDoesNotPretendToContainUsableState() async throws {
        let fixture = TargetObservationFixture()
        fixture.text = fixture.text.components(separatedBy: "\n").prefix(4).joined(separator: "\n")
        fixture.image = .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string("invalid")])
        let adapter = fixture.adapter()
        await #expect(throws: TargetBoundNativeObservation.Failure.noUsableState) {
            try await adapter.observe(adapter.prepare(fixture.preparation()))
        }
        #expect(adapter.latest == nil)
        adapter.stop(); await adapter.drain()
    }

    @Test func literalWindowTextCannotNormalizeDifferentUnicodeIntoTheSameTarget() {
        let fixture = TargetObservationFixture()
        let original = fixture.window
        let other = TargetBoundNativeObservation.WindowInfo(title: original.title.replacingOccurrences(of: "é", with: "e\u{301}"),
            role: original.role, identifier: original.identifier, document: original.document, url: original.url,
            x: original.x, y: original.y, width: original.width, height: original.height,
            minimized: original.minimized, hidden: original.hidden, modal: original.modal)
        #expect(original.title == other.title)
        #expect(!original.matchesExactly(other))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_TARGET_BOUND_NATIVE_FIXTURE_TEST"] == "1"))
    func actualNativeObservationIsBoundToTheExclusiveFixtureProcessAndWindow() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath) { fixture in
            try fixture.requireExclusiveProcess()
            let client = try await OwnedNativeComputerUseClient.open(runtime: .discover())
            let adapter = TargetBoundNativeObservation(client: client, sessionIsActive: { true })
            do {
                let snapshot = try await adapter.observe(adapter.prepare(application: fixture.application))
                #expect(snapshot.application.processID == fixture.application.processIdentifier)
                #expect(snapshot.text.contains(fixture.token) && snapshot.window.title == "Relay Accessibility Fixture")
                #expect(!snapshot.images.isEmpty && !snapshot.references.isEmpty && adapter.isCurrent(snapshot))
                adapter.stop(); await adapter.drain()
                #expect(!adapter.isCurrent(snapshot) && adapter.latest == nil)
            } catch { adapter.stop(); await adapter.drain(); throw error }
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TargetBoundNativeObservation.Failure.busy
    }

    private func image(width: Int, height: Int) throws -> JSONValue {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string((data as Data).base64EncodedString())])
    }
}

@MainActor
private final class TargetObservationFixture {
    let application = DesktopApplicationIdentity(processID: 4_242, launchedAt: Date(timeIntervalSince1970: 1_000),
        bundleID: "test.synthetic.fixture", bundleURL: URL(fileURLWithPath: "/Applications/Synthetic Fixture.app", isDirectory: true))
    let window = TargetBoundNativeObservation.WindowInfo(title: "Synthetic \"window\" — café", role: "AXWindow", identifier: "fixture.window",
        document: "fixture://original", url: "", x: 10, y: 20, width: 560, height: 300, minimized: false, hidden: nil, modal: false)
    var processGeneration = 1, windowGeneration = 1, documentGeneration = 1, tabGeneration = 1
    var url = "https://synthetic.invalid/original"
    var validationError: TargetBoundNativeObservation.Failure?
    var text = TargetObservationFixture.text()
    var image: JSONValue?
    var active = true
    var paused = false
    var captures: [String] = []
    var closeCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    var backend: TargetBoundNativeObservation.Backend {
        .init(capture: { [self] _, app in
            captures.append(app)
            if paused { await withCheckedContinuation { continuation = $0 } }
            let content = [JSONValue.object(["type": .string("text"), "text": .string(text)])] + (image.map { [$0] } ?? [])
            return OwnedNativeComputerUseClient.NativeResult(raw: .object(["content": .array(content)]), content: content, isError: false)
        }, close: { [self] in closeCount += 1 })
    }

    func adapter() -> TargetBoundNativeObservation {
        TargetBoundNativeObservation(backend: backend, sessionIsActive: { [self] in active })
    }

    func preparation() -> TargetBoundNativeObservation.Preparation {
        let process = processGeneration, windowID = windowGeneration, document = documentGeneration, tab = tabGeneration, selectedURL = url
        return .init(application: application, window: window, validate: { [self] in
            if let validationError { throw validationError }
            guard processGeneration == process, windowGeneration == windowID, documentGeneration == document,
                  tabGeneration == tab, url == selectedURL else { throw TargetBoundNativeObservation.Failure.changedTarget }
        })
    }

    func release() { continuation?.resume(); continuation = nil; paused = false }

    nonisolated static func text() -> String {
        """
        Computer Use state (CUA App Version: 1001824)
        <app_state>
        App=/Applications/Synthetic Fixture.app/ (bundleID test.synthetic.fixture, pid 4242)
        Window: "Synthetic "window" — café", App: Synthetic Fixture.
        0 standard window Synthetic "window" — café, ID: fixture.window
        \t1 text field (settable) Description: Synthetic input, ID: fixture.input
        \t2 button Apply, ID: fixture.apply
        </app_state>
        The focused UI element is 1 text field (settable) Description: Synthetic input
        """
    }
}

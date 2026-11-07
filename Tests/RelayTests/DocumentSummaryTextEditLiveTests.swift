import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Uses the real supported TextEdit app and default production capture, never a
/// fixture-specific profile, substituted bundle ID, captured-source stub or grant.
@Suite(.serialized)
@MainActor
struct DocumentSummaryTextEditLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_TEXTEDIT_SUMMARY_TEST"] == "1"), .timeLimit(.minutes(2)))
    func supportedTextEditCaptureAndCoordinatorReadOnlyTheOwnedNonceDocument() async throws {
        try await withOwnedTextEdit { fixture in
            try fixture.pin.validate()
            let request = try SummaryNativeDocumentCapture.prepare(application: fixture.application,
                isActive: { fixture.pin.isCurrent })
            let snapshot = try await SummaryNativeDocumentCapture.capture(request)
            #expect(snapshot.mode == .document && snapshot.text == fixture.body)
            #expect(snapshot.origin.application == fixture.pin.identity)
            #expect(snapshot.origin.window.title == fixture.pin.title)
            #expect(!snapshot.truncated && snapshot.documentURL == nil)
            try fixture.requireUnchangedFile()

            var generations = 0
            let summaries = DocumentSummaryCoordinator(generate: { messages in
                generations += 1
                let payload = try JSONDecoder().decode([String: String].self,
                    from: Data(try #require(messages.last?.content).utf8))
                #expect(payload["source_text"] == fixture.body)
                #expect(payload["source_title"] == fixture.pin.title)
                #expect(payload["capture_coverage"]?.contains("exact originating native document window") == true)
                #expect(messages.allSatisfy { $0.toolCalls.isEmpty })
                return ModelReply(content: "The final decision is 73 widgets. " + fixture.releaseCode, toolCalls: [])
            })
            defer { summaries.closeAll() }
            // Do not override prepareNativeCapture: this is the production app
            // profile admission, AX capture, source mapping and coordinator path.
            let session = try summaries.startNative(application: fixture.application,
                requiredKind: .nativeDocument, isActive: { fixture.pin.isCurrent })
            try await waitForSummary(summaries, deadline: .seconds(8))
            print("Owned TextEdit coordinator: phase=\(session.phase), generations=\(generations), error=\(session.errorMessage ?? "none").")
            try #require(session.phase == .ready && generations == 1,
                Comment(rawValue: session.errorMessage ?? "The native summary must complete exactly once."))
            #expect(session.source?.kind == .nativeDocument && session.source?.text == fixture.body)
            #expect(session.source?.location == nil && session.resultText.contains(fixture.releaseCode))
            try fixture.pin.validate()
            try fixture.requireUnchangedFile()
            summaries.closeAll()
            #expect(summaries.sessions.isEmpty && session.source == nil && session.resultText.isEmpty)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_TEXTEDIT_SUMMARY_TEST"] == "1"
        && ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"] != nil), .timeLimit(.minutes(5)))
    func actualE2BSummarizesTheDefaultSupportedTextEditCaptureWithoutTools() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"])
        try #require(URL(fileURLWithPath: path).lastPathComponent == "gemma-4-E2B-it.litertlm")
        let model = LocalModelClient()
        defer { model.unload() }
        let configuration = ModelConfiguration(modelPath: path, computeBackend: "cpu", model: "Gemma 4 E2B")
        try await withOwnedTextEdit { fixture in
            var generations = 0
            let summaries = DocumentSummaryCoordinator(generate: { messages in
                generations += 1
                let payload = try JSONDecoder().decode([String: String].self,
                    from: Data(try #require(messages.last?.content).utf8))
                try #require(payload["source_text"] == fixture.body)
                let reply = try await model.complete(messages: messages, tools: [], configuration: configuration)
                #expect(reply.toolCalls.isEmpty)
                return reply
            })
            defer { summaries.closeAll() }
            let session = try summaries.startNative(application: fixture.application,
                requiredKind: .nativeDocument, isActive: { fixture.pin.isCurrent })
            try await waitForSummary(summaries, deadline: .seconds(185))
            try #require(session.phase == .ready && generations == 1,
                Comment(rawValue: session.errorMessage ?? "One tool-free production capture/summary must finish."))
            print("Owned TextEdit synthetic summary: \(session.resultText)")
            #expect(session.resultText.contains(fixture.releaseCode))
            #expect(session.resultText.contains("73") && session.resultText.contains("2026-11-12"))
            try fixture.pin.validate()
            try fixture.requireUnchangedFile()
            summaries.closeAll()
            #expect(session.source == nil && session.resultText.isEmpty && summaries.sessions.isEmpty)
        }
    }

    private struct Fixture {
        let application: NSRunningApplication
        let file: URL
        let body: String
        let originalBytes: Data
        let releaseCode: String
        let pin: MetadataPin
        func requireUnchangedFile() throws {
            #expect(try Data(contentsOf: file) == originalBytes, "Independent file bytes must remain unchanged.")
        }
    }

    /// Reads metadata only: no AXValue, selected text, children, menus or app
    /// body is inspected here. Exact nonce authority precedes production scan.
    @MainActor private struct MetadataPin {
        let application: NSRunningApplication
        let identity: DesktopApplicationIdentity
        let root: AXUIElement
        let window: AXUIElement
        let title: String
        let document: String
        let file: URL
        var isCurrent: Bool { (try? validate()) != nil }
        func validate() throws {
            guard DesktopApplicationTarget.matches(identity, application: application),
                  Self.runningPIDs() == [identity.processID] else {
                print("Owned TextEdit pin process mismatch: identity=\(DesktopApplicationTarget.matches(identity, application: application)), samePID=\(Self.runningPIDs() == [identity.processID]).")
                throw IsolationFailure.process
            }
            let windows = try Self.windows(root)
            guard windows.count == 1, CFEqual(windows[0], window),
                  Self.string(window, "AXRole") == "AXWindow",
                  Self.string(window, "AXTitle").utf16.elementsEqual(title.utf16),
                  Self.string(window, "AXDocument").utf16.elementsEqual(document.utf16),
                  try Self.documentURL(window) == file,
                  (Self.attribute(window, "AXMinimized") as? Bool) == false,
                  let focused = Self.element(root, "AXFocusedWindow"), CFEqual(focused, window) else {
                print("Owned TextEdit pin window mismatch: count=\(windows.count), sameWindow=\(windows.count == 1 && CFEqual(windows[0], window)), role=\(Self.string(window, "AXRole") == "AXWindow"), sameTitle=\(Self.string(window, "AXTitle").utf16.elementsEqual(title.utf16)), sameDocument=\(Self.string(window, "AXDocument").utf16.elementsEqual(document.utf16)), minimized=\(String(describing: Self.attribute(window, "AXMinimized") as? Bool)), sameFocus=\(Self.element(root, "AXFocusedWindow").map { CFEqual($0, window) } ?? false).")
                throw IsolationFailure.window
            }
        }
        static func runningPIDs() -> Set<pid_t> {
            Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
                .filter { !$0.isTerminated }.map(\.processIdentifier))
        }
        static func windows(_ root: AXUIElement) throws -> [AXUIElement] {
            guard let windows = attribute(root, "AXWindows") as? [AXUIElement] else { throw IsolationFailure.window }
            return windows
        }
        static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        static func string(_ element: AXUIElement, _ name: String) -> String {
            if let url = attribute(element, name) as? URL { return url.absoluteString }
            return attribute(element, name) as? String ?? ""
        }
        static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
            guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        static func documentURL(_ element: AXUIElement) throws -> URL {
            guard let value = URL(string: string(element, "AXDocument")), value.isFileURL,
                  value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
                  value.host == nil || value.host == "" || value.host == "localhost" else { throw IsolationFailure.window }
            return value.resolvingSymlinksInPath().standardizedFileURL
        }
    }

    private enum IsolationFailure: Error {
        case existingApplication, process, window, launch
    }

    private func withOwnedTextEdit(_ body: (Fixture) async throws -> Void) async throws {
        try #require(AXIsProcessTrusted(), "This opt-in uses existing test-host Accessibility permission; it never requests access.")
        guard MetadataPin.runningPIDs().isEmpty else { throw IsolationFailure.existingApplication }
        let appURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true)
        try #require(Bundle(url: appURL)?.bundleIdentifier == "com.apple.TextEdit")
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-native-textedit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let token = UUID().uuidString
        let file = directory.appending(path: "Relay-owned-summary-" + token + ".txt").resolvingSymlinksInPath().standardizedFileURL
        let code = "RELEASE-" + String(UUID().uuidString.prefix(8))
        let text = "Synthetic launch record. An earlier proposal of 25 widgets was rejected.\n"
            + (1...12).map { "Working note \($0): the team reviewed the local release checklist. No final decision was made here." }.joined(separator: "\n")
            + "\nFINAL CONFIRMED DECISION: Ship 73 widgets on 2026-11-12. Release code: " + code + ". Café 🌍.\n"
        let bytes = Data(text.utf8)
        try bytes.write(to: file, options: .atomic)
        let launchStarted = Date()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        // NSArgumentDomain overrides are volatile. Apple documents the first
        // argument specifically for tests: restored documents are ignored and
        // new restoration/autosave state is redirected to a temporary folder.
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
            "-NSRecentDocumentsLimit", "0"]
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: configuration)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
        // Launch Services can return before the running-app registry publishes
        // this new PID. Wait for that metadata; never substitute another PID.
        for _ in 0..<20 {
            let published = MetadataPin.runningPIDs()
            guard published.isSubset(of: [app.processIdentifier]) else { throw IsolationFailure.process }
            if published == [app.processIdentifier], DesktopApplicationTarget.identity(of: app) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        print("Owned TextEdit launch metadata: returnedPID=\(app.processIdentifier), terminated=\(app.isTerminated), runningPIDs=\(MetadataPin.runningPIDs().sorted()), correctBundle=\(app.bundleIdentifier == "com.apple.TextEdit"), correctPath=\(app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == appURL), launchDelta=\(app.launchDate.map { $0.timeIntervalSince(launchStarted) } ?? -999).")
        guard let identity = DesktopApplicationTarget.identity(of: app), identity.bundleID == "com.apple.TextEdit",
              identity.bundleURL == appURL, identity.launchedAt >= launchStarted.addingTimeInterval(-1),
              MetadataPin.runningPIDs() == [identity.processID] else {
            // If the launch service substituted an unowned process, never quit
            // or inspect it. Retain the synthetic file for explicit cleanup.
            throw IsolationFailure.process
        }
        var terminated = false
        do {
            let root = AXUIElementCreateApplication(identity.processID)
            AXUIElementSetMessagingTimeout(root, 0.03)
            var pin: MetadataPin?
            for _ in 0..<100 {
                try Task.checkCancellation()
                guard DesktopApplicationTarget.matches(identity, application: app),
                      MetadataPin.runningPIDs() == [identity.processID] else { throw IsolationFailure.process }
                guard let windows = try? MetadataPin.windows(root) else {
                    try await Task.sleep(for: .milliseconds(50)); continue
                }
                if windows.isEmpty { try await Task.sleep(for: .milliseconds(50)); continue }
                guard windows.count == 1 else { throw IsolationFailure.window }
                let window = windows[0]
                AXUIElementSetMessagingTimeout(window, 0.03)
                let title = MetadataPin.string(window, "AXTitle")
                let permittedTitles = [file.lastPathComponent, file.deletingPathExtension().lastPathComponent]
                guard permittedTitles.contains(where: { $0.utf16.elementsEqual(title.utf16) }),
                      try MetadataPin.documentURL(window) == file else { throw IsolationFailure.window }
                let candidate = MetadataPin(application: app, identity: identity, root: root, window: window,
                    title: title, document: MetadataPin.string(window, "AXDocument"), file: file)
                try candidate.validate(); pin = candidate; break
            }
            let metadata = try #require(pin, "The exact isolated nonce document never became available; no body capture is permitted.")
            let fixture = Fixture(application: app, file: file, body: text, originalBytes: bytes, releaseCode: code, pin: metadata)
            try await body(fixture)
            try fixture.requireUnchangedFile()
            terminated = await stopOwnedTextEdit(app, identity: identity, file: file)
        } catch {
            terminated = await stopOwnedTextEdit(app, identity: identity, file: file)
            if terminated { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
        #expect(terminated, "The owned TextEdit process must exit before its synthetic file is removed.")
        if terminated { try FileManager.default.removeItem(at: directory) }
    }

    private func stopOwnedTextEdit(_ application: NSRunningApplication, identity: DesktopApplicationIdentity, file: URL) async -> Bool {
        await Task { @MainActor in
            guard DesktopApplicationTarget.matches(identity, application: application) else { return application.isTerminated }
            // If a restored or externally opened foreign document appeared in
            // this process, abort cleanup instead of closing user-owned work.
            let root = AXUIElementCreateApplication(identity.processID)
            AXUIElementSetMessagingTimeout(root, 0.03)
            guard let windows = try? MetadataPin.windows(root), windows.count <= 1,
                  windows.allSatisfy({ (try? MetadataPin.documentURL($0)) == file }) else { return false }
            application.terminate()
            for _ in 0..<40 where !application.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
            if !application.isTerminated, DesktopApplicationTarget.matches(identity, application: application) { application.forceTerminate() }
            for _ in 0..<20 where !application.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
            return application.isTerminated
        }.value
    }

    private func waitForSummary(_ coordinator: DocumentSummaryCoordinator, deadline: Duration) async throws {
        let end = ContinuousClock.now.advanced(by: deadline)
        while coordinator.isBusy, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(25)) }
        try #require(!coordinator.isBusy, "The owned native summary did not settle within its bounded wait.")
    }
}

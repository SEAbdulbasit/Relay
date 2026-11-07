import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Explicit opt-in only. The browser profile, loopback server and native fixture
/// are test-owned; existing browser processes and personal tabs are never read.
@Suite(.serialized)
@MainActor
struct DocumentSummaryBrowserLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_DOCUMENT_SUMMARY_BROWSER_TEST"] == "1"), .timeLimit(.minutes(3)))
    func ownedBackgroundChromeDocumentCapturesOffscreenTextAndReadersCloseIndependently() async throws {
        try #require(AXIsProcessTrusted(), "Existing Accessibility permission is required; this test never requests it.")
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-summary-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = """
        <!doctype html><html><head><title>Relay current-document summary fixture</title>
        <style>p{margin:0 0 110px}body{font-family:system-ui}</style></head><body><main>
        <h1>Relay current-document summary fixture</h1>
        \((1...24).map { "<p>Paragraph \($0): This synthetic record contains ordinary bounded notes for the local summary test.</p>" }.joined())
        <p>FINAL DECISION: RELEASE-6293 ships 47 units.</p>
        <input aria-label="Disposable form value" value="FORM_VALUE_MUST_STAY_OUT_OF_SUMMARY_SOURCE">
        </main></body></html>
        """
        try Data(html.utf8).write(to: directory.appending(path: "index.html"))
        let portFile = directory.appending(path: "port.txt")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
        import functools,http.server,pathlib,sys
        handler=functools.partial(http.server.SimpleHTTPRequestHandler,directory=sys.argv[1])
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),handler)
        pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
        server.serve_forever()
        """, directory.path, portFile.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: portFile.path) { try await Task.sleep(for: .milliseconds(50)) }
        let port = try #require(Int(try String(contentsOf: portFile, encoding: .utf8)))
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/index.html"))
        let chromeURL = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"))
        let priorPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").map(\.processIdentifier))
        let profile = directory.appending(path: "ChromeProfile")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--disable-sync", "--new-window", url.absoluteString]
        let browser = try await NSWorkspace.shared.openApplication(at: chromeURL, configuration: configuration)
        try #require(!priorPIDs.contains(browser.processIdentifier) && browser.bundleIdentifier == "com.google.Chrome")
        defer { if !browser.isTerminated { browser.terminate() } }
        for _ in 0..<60 where NSWorkspace.shared.frontmostApplication?.processIdentifier != browser.processIdentifier {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await BrowserAccessibility.prepareContent(for: browser)
        var snapshot: BrowserPageReader.Snapshot?
        for _ in 0..<40 {
            if let value = try? await BrowserPageReader.readCurrent(application: browser), value.url == url.absoluteString { snapshot = value; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let initial = try #require(snapshot)
        #expect(initial.text.contains("FINAL DECISION: RELEASE-6293"))
        #expect(!initial.text.contains("FORM_VALUE_MUST_STAY_OUT_OF_SUMMARY_SOURCE"))
        let pinned = try BrowserPageReader.captureCurrentTarget(application: browser)
        let originalWindow = try selectedWindow(of: browser)
        try BrowserPageReader.validateCurrentTarget(pinned, expectedWindow: originalWindow)
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath) { fixture in
            try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.application.processIdentifier)
            let differentWindow = try selectedWindow(of: fixture.application)
            #expect(throws: RelayError.self) { try BrowserPageReader.validateCurrentTarget(pinned, expectedWindow: differentWindow) }
            #expect(throws: RelayError.self) { try BrowserPageReader.captureCurrentTarget(application: browser, expectedWindow: differentWindow) }
            try BrowserPageReader.validateCurrentTarget(pinned, expectedWindow: originalWindow)
            let current = try await BrowserPageReader.readCurrent(target: pinned)
            try BrowserPageReader.validateCurrentTarget(pinned, expectedWindow: originalWindow)
            #expect(current.url == url.absoluteString && current.title == initial.title)
            #expect(current.text.contains("RELEASE-6293"))
            #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.application.processIdentifier,
                "A background current-document read must not activate the browser")
            let summaries = DocumentSummaryCoordinator(generate: { _ in ModelReply(content: "Fixture decision: 47 units, RELEASE-6293.", toolCalls: []) })
            let first = try summaries.startBrowser(application: browser)
            let second = try summaries.start { try DocumentSummarySource(kind: .selection, title: "Second synthetic source",
                application: "Fixture", text: "Separate comparison text.", coverage: "Synthetic selection.") }
            for _ in 0..<1_000 where summaries.isBusy { await Task.yield() }
            #expect(first.phase == .ready && second.phase == .ready)
            try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.application.processIdentifier,
                "The entire background coordinator capture must preserve fixture foreground before reader creation")
            let panels = DocumentSummaryPanelController()
            panels.present(session: first, coordinator: summaries)
            panels.present(session: second, coordinator: summaries)
            #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.application.processIdentifier,
                "Opening readers must preserve the source app's focus")
            panels.close(id: first.id)
            #expect(first.source == nil && first.resultText.isEmpty)
            #expect(second.phase == .ready && !second.resultText.isEmpty && second.source != nil)
            panels.closeAll()
            #expect(second.source == nil && second.resultText.isEmpty && summaries.sessions.isEmpty)
        }
        browser.terminate()
        for _ in 0..<40 where !browser.isTerminated { try await Task.sleep(for: .milliseconds(50)) }
        if !browser.isTerminated { browser.forceTerminate() }
        for _ in 0..<20 where !browser.isTerminated { try await Task.sleep(for: .milliseconds(50)) }
        #expect(browser.isTerminated, "The test-owned browser must exit before its disposable profile is removed.")
    }

    private func selectedWindow(of app: NSRunningApplication) throws -> AXUIElement {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        var value: CFTypeRef?
        try #require(AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &value) == .success)
        let window = try #require(value)
        try #require(CFGetTypeID(window) == AXUIElementGetTypeID())
        return window as! AXUIElement
    }
}

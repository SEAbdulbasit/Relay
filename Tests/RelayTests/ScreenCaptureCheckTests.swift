import AppKit
import ApplicationServices
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Relay

@MainActor
struct ScreenCaptureCheckTests {
    @Test func visibleMarkerMustMatchTheFixtureLaunch() async throws {
        let image = try bitmap(text: "RELAY SCREEN CHECK 24681")
        #expect(try await ScreenCaptureCheck.markerIsVisible(in: image, nonce: "24681"))
        #expect(try await !ScreenCaptureCheck.markerIsVisible(in: image, nonce: "24682"))
        let titleOnly = try bitmap(text: "Relay Capture Fixture 24681")
        #expect(try await !ScreenCaptureCheck.markerIsVisible(in: titleOnly, nonce: "24681"))
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCREEN_CAPTURE_TEST"] == "1"),
        .timeLimit(.minutes(1))
    )
    func realBundledWindowCaptureReadsItsLaunchMarker() async throws {
        _ = NSApplication.shared
        try #require(CGPreflightScreenCaptureAccess(),
                     "The test runner needs existing macOS screen capture permission. This test never requests it.")
        let path = try #require(ProcessInfo.processInfo.environment["RELAY_AX_FIXTURE_APP"],
                                "Set RELAY_AX_FIXTURE_APP to the bundled RelayAccessibilityFixture.app.")
        try #require(path.hasPrefix("/"), "RELAY_AX_FIXTURE_APP must be an absolute path.")
        let report = try await ScreenCaptureCheck.run(fixtureURL: URL(fileURLWithPath: path))
        #expect(report.allPassed, Comment(rawValue: report.summary))
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCREEN_CAPTURE_TEST"] == "1"),
        .timeLimit(.minutes(1))
    )
    func realSidekickVisualReadUsesTheSelectedWindowAndRejectsAnExitedApp() async throws {
        _ = NSApplication.shared
        try #require(CGPreflightScreenCaptureAccess() && AXIsProcessTrusted(),
                     "This test requires existing macOS Accessibility and screen capture permissions.")
        let path = try #require(ProcessInfo.processInfo.environment["RELAY_AX_FIXTURE_APP"])
        let fixture = URL(fileURLWithPath: path)
        let bundleID = AccessibilityCheckRunner.fixtureBundleID
        try #require(Bundle(url: fixture)?.bundleIdentifier == bundleID)
        for _ in 0..<20 where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty)
        let nonce = String(Int.random(in: 10_000...99_999))
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = true
        config.environment = ["RELAY_FIXTURE_SCREEN_MARKER": nonce]
        let app = try await NSWorkspace.shared.openApplication(at: fixture, configuration: config)
        defer { if !app.isTerminated { app.terminate() } }
        var target: SidekickWindowText.Target?
        for _ in 0..<20 {
            target = SidekickWindowText.target(for: app)
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let selected = try #require(target)
        #expect(selected.title == "Relay Capture Fixture " + nonce)
        let marker = "RELAY SCREEN CHECK " + nonce
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "relay-visual-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = directory.appending(path: "state.json")
        var windowReads = 0
        var nextTaskSawMarker = false
        let store = AssistantStore(persistenceURL: history, complete: { messages, tools, _ in
            if messages.last?.content == "Start a separate task." {
                nextTaskSawMarker = messages.contains { $0.content.contains(marker) }
                #expect(!tools.contains { $0.name == "read_sidekick_window" })
                return ModelReply(content: "Separate task complete.", toolCalls: [])
            }
            if messages.last?.role == "tool" {
                if messages.last?.content.contains(marker) == true { windowReads += 1 }
                return ModelReply(content: "Read the fixture window.", toolCalls: [])
            }
            #expect(tools.contains { $0.name == "read_sidekick_window" })
            return ModelReply(content: "", toolCalls: [ToolCall(name: "read_sidekick_window", arguments: [:])])
        })
        store.draft = "Read the text in this window."
        store.send(sidekickContext: SidekickTaskContext(appID: bundleID, instructions: "", visualTarget: selected))
        try await waitForRun(store)
        #expect(windowReads == 1)
        #expect(store.activity.contains { $0.name == "read_sidekick_window" && $0.status == "verified" })
        #expect(try !String(contentsOf: history, encoding: .utf8).contains(marker))
        store.draft = "Start a separate task."
        store.send()
        try await waitForRun(store)
        #expect(!nextTaskSawMarker)

        app.terminate()
        for _ in 0..<20 where !app.isTerminated { try await Task.sleep(for: .milliseconds(100)) }
        try #require(app.isTerminated)
        await #expect(throws: RelayError.self) { try await SidekickWindowText.read(selected) }
    }

    private func waitForRun(_ store: AssistantStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!store.isRunning)
    }

    private func bitmap(text: String) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 1_120, height: 160, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_120, height: 160))
        let text = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo-Bold" as CFString, 56, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 35, y: 57)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return try #require(context.makeImage())
    }
}

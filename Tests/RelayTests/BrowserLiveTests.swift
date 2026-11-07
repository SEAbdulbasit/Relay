import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor
struct BrowserLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_BROWSER_TEST"] == "1"), .timeLimit(.minutes(2)), arguments: [false, true])
    func disposableChromeProfileNavigatesAndReadsOnlyTheLoopbackFixture(withoutStartupWindow: Bool) async throws {
        try #require(AXIsProcessTrusted(), "This test uses existing Accessibility permission.")
        let raw = try #require(ProcessInfo.processInfo.environment["RELAY_BROWSER_FIXTURE_URL"])
        let url = try BrowserAutomation.validatedURL(raw)
        try #require(url.host == "127.0.0.1" && url.path.hasPrefix("/fixture/"))
        let chromeURL = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserAutomation.Browser.chrome.rawValue))
        let priorPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: BrowserAutomation.Browser.chrome.rawValue)
            .map(\.processIdentifier))
        let profile = FileManager.default.temporaryDirectory.appending(path: "relay-chrome-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: profile) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
                                   "--disable-background-networking", "--disable-sync"]
            + (withoutStartupWindow ? ["--no-startup-window"] : ["--new-window", "about:blank"])
        let app = try await NSWorkspace.shared.openApplication(at: chromeURL, configuration: configuration)
        try #require(!priorPIDs.contains(app.processIdentifier) && app.bundleIdentifier == BrowserAutomation.Browser.chrome.rawValue,
                     "Chrome must launch a new test-owned profile. Existing browser processes are left alone.")
        defer { if !app.isTerminated { app.terminate() } }
        app.activate()
        for _ in 0..<60 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier)
        let navigation = try await BrowserAutomation.navigate(url: url, browser: .chrome)
        #expect(navigation.verified, Comment(rawValue: navigation.summary + "\n" + navigation.evidence))
        let readback = try await BrowserPageReader.read(expectedURL: raw, browser: "Google Chrome")
        #expect(BrowserAutomation.matchesDestination(readback.url, expected: url))
        #expect(readback.text.contains("Relay browser fixture"))
        #expect(!readback.text.contains("FORM_VALUE_MUST_NOT_APPEAR_IN_PAGE_READ"))
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier)
        app.terminate()
        for _ in 0..<30 where !app.isTerminated { try await Task.sleep(for: .milliseconds(100)) }
        if !app.isTerminated {
            app.forceTerminate()
            for _ in 0..<20 where !app.isTerminated { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(app.isTerminated, "The test-owned browser must close before its temporary profile is removed.")
    }
}

import AppKit
import Foundation
import Testing
@testable import Relay

@MainActor
struct DesktopFixtureProcess {
    let application: NSRunningApplication
    let oracleURL: URL
    let token: String

    private static let bundleID = AccessibilityCheckRunner.fixtureBundleID

    static var bundledPath: String {
        ProcessInfo.processInfo.environment["RELAY_AX_FIXTURE_APP"]
            ?? FileManager.default.currentDirectoryPath + "/build/Relay.app/Contents/Resources/RelayAccessibilityFixture.app"
    }

    static func withLaunch(path: String, environment: [String: String] = [:],
                           body: (DesktopFixtureProcess) async throws -> Void) async throws {
        let url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        try #require(Bundle(url: url)?.bundleIdentifier == bundleID)
        // Other suites may have requested a graceful quit just before this test started.
        for _ in 0..<30 where !runningApplications().isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(runningApplications().isEmpty, "Close the existing Relay fixture before running the desktop tests.")

        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-desktop-test-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let oracleURL = directory.appending(path: "oracle.json")
        let token = UUID().uuidString
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = true
        config.environment = environment.merging(["RELAY_FIXTURE_TOKEN": token, "RELAY_FIXTURE_STATE_PATH": oracleURL.path]) { _, launchValue in launchValue }
        let application = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        try #require(application.bundleIdentifier == bundleID && application.bundleURL?.resolvingSymlinksInPath().path == url.path,
                     "The new process must match the test fixture bundle before this test can control or terminate it.")

        let fixture = Self(application: application, oracleURL: oracleURL, token: token)
        do {
            try await fixture.waitForLaunch()
            try await body(fixture)
        } catch {
            await fixture.terminateAndWait()
            throw error
        }
        await fixture.terminateAndWait()
    }

    func requireExclusiveProcess() throws {
        try #require(!application.isTerminated && Self.runningApplications().map(\.processIdentifier) == [application.processIdentifier],
                     "The test-owned fixture must be the only running process with this bundle identifier.")
    }

    private static func runningApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }

    private struct LaunchOracle: Decodable { let launchToken: String }

    private func waitForLaunch() async throws {
        func launchToken() -> String? {
            guard let data = try? Data(contentsOf: oracleURL) else { return nil }
            return (try? JSONDecoder().decode(LaunchOracle.self, from: data))?.launchToken
        }
        for _ in 0..<50 {
            if launchToken() == token || application.isTerminated { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(launchToken() == token, "The fixture did not produce an oracle with the expected launch token.")
        try requireExclusiveProcess()
    }

    private func terminateAndWait() async {
        // A separate task lets cleanup finish even if the test body was cancelled.
        let exited = await Task { @MainActor in
            if !application.isTerminated { application.terminate() }
            if await waitForExit() { return true }
            if !application.isTerminated { application.forceTerminate() }
            return await waitForExit()
        }.value
        #expect(exited, "The test-owned Relay fixture did not exit after termination.")
    }

    private func waitForExit() async -> Bool {
        for _ in 0..<40 {
            if application.isTerminated { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return application.isTerminated
    }
}

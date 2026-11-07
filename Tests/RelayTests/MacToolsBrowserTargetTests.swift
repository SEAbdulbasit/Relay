import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Uses two disposable profiles and only the synthetic loopback form. Existing
/// Chrome processes are counted for ambiguity, never inspected or terminated.
@Suite(.serialized) @MainActor
struct MacToolsBrowserTargetTests {
    private struct OwnedProfile {
        let app: NSRunningApplication
        let identity: DesktopApplicationIdentity
        let directory: URL
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_BROWSER_TARGET_TEST"] == "1"), .timeLimit(.minutes(2)))
    func nativeControlsBindToTheExactForegroundProfileAndRejectOtherProfileRefs() async throws {
        try #require(AXIsProcessTrusted(), "This test uses existing Accessibility access only.")
        let fixture = try BrowserAutomation.validatedURL(#require(ProcessInfo.processInfo.environment["RELAY_BROWSER_FIXTURE_URL"]))
        try #require(fixture.host == "127.0.0.1" && fixture.path.hasPrefix("/fixture/"))
        let applicationURL = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"))
            .resolvingSymlinksInPath().standardizedFileURL
        var owned: [OwnedProfile] = []
        do {
            for _ in 0..<2 {
                let prior = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").map(\.processIdentifier))
                let directory = FileManager.default.temporaryDirectory.appending(path: "relay-target-test-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = true
                configuration.arguments = ["--user-data-dir=\(directory.path)", "--no-first-run", "--no-default-browser-check",
                    "--disable-sync", "--disable-background-networking", "--new-window", fixture.absoluteString]
                let app = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
                let identity = try #require(DesktopApplicationTarget.identity(of: app))
                try #require(!prior.contains(identity.processID) && identity.bundleID == "com.google.Chrome" && identity.bundleURL == applicationURL,
                    "Only a newly launched exact Chrome process may be controlled or terminated.")
                owned.append(OwnedProfile(app: app, identity: identity, directory: directory))
                try await foreground(owned.last!)
            }
            let first = owned[0]
            let second = owned[1]
            let tools = MacTools()
            try await foreground(first)
            let original = try await field(tools, expected: first.identity)
            #expect(original.line.contains("FORM_VALUE_MUST_NOT_APPEAR_IN_PAGE_READ"))
            try await foreground(second)
            let stale = ToolCall(name: "set_value", arguments: ["bundle_id": .string("com.google.Chrome"),
                "element_id": .string(original.id), "value": .string("WRONG_PROFILE_MUST_STAY_UNCHANGED")])
            await #expect(throws: (any Error).self) { try await tools.execute(stale) }

            let selected = try await field(tools, expected: second.identity)
            let payload = "Owned second profile — café 🌍"
            let write = ToolCall(name: "set_value", arguments: ["bundle_id": .string("com.google.Chrome"),
                "element_id": .string(selected.id), "value": .string(payload)])
            let readback = try #require(try tools.prepareMutationReadback(for: write))
            let receipt = try await tools.execute(write)
            #expect(receipt.verified)

            try await foreground(first)
            await #expect(throws: (any Error).self) { try await tools.readback(readback, after: write) }
            let unchanged = try await field(tools, expected: first.identity)
            #expect(unchanged.line.contains("FORM_VALUE_MUST_NOT_APPEAR_IN_PAGE_READ"))
            #expect(!unchanged.line.contains(payload) && !unchanged.line.contains("WRONG_PROFILE"))
            // Closing the captured process cannot redirect its cached ref into the
            // remaining profile, even when that profile is now the selected one.
            _ = first.app.terminate()
            for _ in 0..<40 where !first.app.isTerminated { try await Task.sleep(for: .milliseconds(50)) }
            try #require(first.app.isTerminated)
            try await foreground(second)
            #expect(try await field(tools, expected: second.identity).line.contains(payload))
            let closed = ToolCall(name: "set_value", arguments: ["bundle_id": .string("com.google.Chrome"),
                "element_id": .string(unchanged.id), "value": .string("CLOSED_PROCESS_MUST_NOT_REBIND")])
            await #expect(throws: (any Error).self) { try await tools.execute(closed) }
            #expect(try await field(tools, expected: second.identity).line.contains(payload))
        } catch {
            await cleanup(owned)
            throw error
        }
        await cleanup(owned)
    }

    private func foreground(_ profile: OwnedProfile) async throws {
        try #require(DesktopApplicationTarget.matches(profile.identity, application: profile.app))
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != profile.identity.processID { _ = profile.app.activate() }
        let root = AXUIElementCreateApplication(profile.identity.processID)
        AXUIElementSetMessagingTimeout(root, 0.05)
        var stable = 0
        for _ in 0..<60 {
            var windows: CFTypeRef?
            let ready = profile.app.isFinishedLaunching
                && AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success
                && (windows as? [AXUIElement])?.isEmpty == false
            if ready && NSWorkspace.shared.frontmostApplication?.processIdentifier == profile.identity.processID {
                stable += 1
                if stable >= 4 { break }
            } else { stable = 0 }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(stable >= 4 && NSWorkspace.shared.frontmostApplication?.processIdentifier == profile.identity.processID)
    }

    private func field(_ tools: MacTools, expected: DesktopApplicationIdentity) async throws -> (id: String, line: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").filter { !$0.isTerminated }
        let identities = running.compactMap { DesktopApplicationTarget.identity(of: $0) }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let selected = DesktopApplicationTarget.select(running, foreground: foreground)
        try #require(selected.flatMap { DesktopApplicationTarget.identity(of: $0) } == expected,
            "Target setup: expectedPID=\(expected.processID), foregroundPID=\(foreground ?? -1), running=\(running.count), identified=\(identities.count), distinctAppPaths=\(Set(identities.map(\.bundleURL)).count).")
        let snapshot = try await tools.execute(ToolCall(name: "observe_app", arguments: ["bundle_id": .string("com.google.Chrome"),
            "mode": .string("find"), "query": .string("Synthetic note")]))
        try #require(snapshot.verified && snapshot.evidence.contains("Native AX") && snapshot.evidence.contains("process \(expected.processID)."),
            "An ambiguous helper name must use the exact selected native process.")
        let rows = snapshot.summary.split(whereSeparator: \.isNewline).filter { $0.contains("role=AXTextField") && $0.contains("Synthetic note") }
        try #require(rows.count == 1, Comment(rawValue: snapshot.summary))
        let token = try #require(rows.first?.split(separator: " ").first)
        try #require(token.hasPrefix("element_id="))
        return (String(token.dropFirst("element_id=".count)), String(rows[0]))
    }

    private func cleanup(_ profiles: [OwnedProfile]) async {
        // Cleanup must finish even if the test body was cancelled.
        await Task { @MainActor in
            for profile in profiles {
                if !profile.app.isTerminated {
                    guard DesktopApplicationTarget.matches(profile.identity, application: profile.app) else { continue }
                    _ = profile.app.terminate()
                    for _ in 0..<40 where !profile.app.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
                    if !profile.app.isTerminated { _ = profile.app.forceTerminate() }
                    for _ in 0..<20 where !profile.app.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
                }
                #expect(profile.app.isTerminated)
                if profile.app.isTerminated { try? FileManager.default.removeItem(at: profile.directory) }
            }
        }.value
    }
}

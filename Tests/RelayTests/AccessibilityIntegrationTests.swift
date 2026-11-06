import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Relay

@MainActor
struct AccessibilityContractTests {
    @Test func observedControlSelectionRequiresExactUniqueIdentifier() throws {
        let snapshot = "element_id=first role=AXTextField identifier=relay.fixture.input value=hello enabled=true\nelement_id=other role=AXTextField identifier=relay.fixture.input.extra value=wrong enabled=true"
        #expect(try AccessibilityCheckRunner.controlID("relay.fixture.input", in: snapshot) == "first")
        #expect(throws: (any Error).self) { try AccessibilityCheckRunner.controlID("missing", in: snapshot) }
        #expect(throws: (any Error).self) { try AccessibilityCheckRunner.controlID("relay.fixture.input", in: snapshot + "\nelement_id=duplicate identifier=relay.fixture.input value=oops") }
    }

    @Test func finderQueryIsLiteralBoundedAndSingleLine() throws {
        #expect(try FinderAutomation.validatedQuery(" sf.webm ") == "sf.webm")
        #expect(try FinderAutomation.validatedQuery("my holiday 🌍.webm") == "my holiday 🌍.webm")
        for bad in ["", " \t ", "sf.webm\nanything", "sf.webm\u{0}", String(repeating: "a", count: 257)] {
            #expect(throws: (any Error).self) { try FinderAutomation.validatedQuery(bad) }
        }
    }

    @Test func unavailableAccessibilityIsExplicitAndDoesNotReportPass() async throws {
        guard !AXIsProcessTrusted() else { return } // Permission-dependent refusal is covered only when absent.
        await #expect(throws: (any Error).self) {
            try await AccessibilityCheckRunner.run(fixtureURL: URL(fileURLWithPath: "/nonexistent/RelayAccessibilityFixture.app"))
        }
    }

    @Test func reportCannotPassWithoutExecutedCases() {
        #expect(!AccessibilityCheckReport(cases: []).allPassed)
        #expect(!AccessibilityCheckReport(cases: [.init(name: "click", passed: false, evidence: "not executed")]).allPassed)
    }

    @Test func multilineEntryPreservesLiteralTextAndRejectsControlCharacters() throws {
        let text = "First line — cafe\u{301} 🌍\nNext\tline"
        #expect(try MacTools.validatedEditableText(text, multiline: true).utf8.elementsEqual(text.utf8))
        #expect(throws: (any Error).self) { try MacTools.validatedEditableText(text, multiline: false) }
        #expect(throws: (any Error).self) { try MacTools.validatedEditableText("NUL\u{0}", multiline: true) }
        #expect(throws: (any Error).self) { try MacTools.validatedEditableText("One\u{2028}Two", multiline: false) }
    }

    @Test func scrollbarTargetMovesInDirectionAndStaysInBounds() {
        #expect(MacTools.scrollTarget(0, within: 0...1, forward: true) == 0.2)
        #expect(MacTools.scrollTarget(0.9, within: 0...1, forward: true) == 1)
        #expect(MacTools.scrollTarget(0.1, within: 0...1, forward: false) == 0)
        #expect(MacTools.scrollTarget(1, within: 0...1, forward: true) == 1)
        #expect(MacTools.scrollTarget(1.1, within: 0...1, forward: false) == nil)
        #expect(MacTools.scrollTarget(1, within: 1...1, forward: true) == nil)
    }
}

/// Explicit opt-in; uses REAL OS accessibility. No mocked AX elements, model or pixel shortcuts.
/// The test process itself needs macOS Accessibility; the app's Settings → Access check is preferred.
@Suite(.serialized)
@MainActor
struct AccessibilityDesktopIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_AX_TESTS"] == "1"))
    func actualTypeClickReadbackStaleDisabledReviewAndStop() async throws {
        let path = ProcessInfo.processInfo.environment["RELAY_AX_FIXTURE_APP"] ?? FileManager.default.currentDirectoryPath + "/build/Relay.app/Contents/Resources/RelayAccessibilityFixture.app"
        let report = try await AccessibilityCheckRunner.run(fixtureURL: URL(fileURLWithPath: path))
        #expect(report.allPassed)
        #expect(report.cases.count == 11)
        #expect(report.cases.contains { $0.name == "Click and verify effect" })
        #expect(report.cases.contains { $0.name == "Invalidation blocks queued click" })
        #expect(report.cases.contains { $0.name == "Scope entry to one window" })
        #expect(report.cases.contains { $0.name == "Scroll the scoped window" })
        #expect(report.cases.contains { $0.name == "Focus the exact window" })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_ATTACHMENT_TEST"] == "1"))
    func stageReviewedFileInTheRealChooserWithoutSelectingIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("relay-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Synthetic attachment 🌍.txt")
        try Data("Original fixture".utf8).write(to: file)
        let canonical = file.resolvingSymlinksInPath().path
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
                                                   environment: ["RELAY_FIXTURE_ATTACHMENT_DIRECTORY": folder.path]) { fixture in
            let tools = MacTools()
            tools.grants = [ScopeGrant(path: file.path, writable: false)]
            let arguments: [String: JSONValue] = ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID), "path": .string(file.path)]
            let original = ToolCall(name: "stage_attachment", arguments: arguments)
            let generic = ToolCall(name: "stage_attachment", arguments: arguments)
            #expect(tools.reviewReason(for: generic)?.contains(canonical) == false)
            // The normal workflow starts with the user opening the system path sheet.
            print("Attachment fixture ready. Press Command–Shift–G in its open chooser.")
            var review: String?
            for _ in 0..<300 {
                review = tools.reviewReason(for: original)
                if review?.contains(canonical) == true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(review?.contains(canonical) == true, "Open Go to Folder with Command–Shift–G while the fixture waits.")
            #expect(!NativeAttachmentStaging.canUseHelperControls(pid: fixture.application.processIdentifier))
            #expect(throws: (any Error).self) { try tools.prepareReview(generic) }
            #expect(throws: (any Error).self) { try tools.authorize(generic) }
            let snapshot = try await tools.execute(ToolCall(name: "observe_app", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID)]))
            if let field = try? AccessibilityCheckRunner.controlID("PathTextField", in: snapshot.summary) {
                await #expect(throws: (any Error).self) {
                    try await tools.execute(ToolCall(name: "set_value", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID),
                                                                                   "element_id": .string(field), "value": .string("/tmp/unscoped")]))
                }
            }
            await #expect(throws: (any Error).self) { try await tools.execute(original) }
            try tools.prepareReview(original)
            try tools.authorize(original)
            try Data("Changed fixture".utf8).write(to: file)
            await #expect(throws: (any Error).self) { try await tools.execute(original) }

            let fresh = ToolCall(name: "stage_attachment", arguments: arguments)
            #expect(tools.reviewReason(for: fresh)?.contains(canonical) == true)
            try tools.prepareReview(fresh)
            try tools.authorize(fresh)
            let staged = try await tools.execute(fresh)
            #expect(staged.verified)
            #expect(staged.summary.contains(file.lastPathComponent))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("file-was-chosen").path))
            await #expect(throws: (any Error).self) { try await tools.execute(fresh) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_FINDER_TEST"] == "1"))
    func actualFinderSearchShowsExactRequestedQuery() async throws {
        // Deliberately visible: opens Finder and searches; does not open/delete a match.
        let result = try await FinderAutomation.search(query: "sf.webm")
        #expect(result.verified)
        #expect(result.summary.contains("sf.webm"))
        #expect(result.evidence.contains("readback matched") && result.evidence.contains("search-results mode"))
        #expect(result.evidence.contains("does not prove a matching file exists"))
    }
}

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
        #expect(report.cases.count == 7)
        #expect(report.cases.contains { $0.name == "Click and verify effect" })
        #expect(report.cases.contains { $0.name == "Invalidation blocks queued click" })
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

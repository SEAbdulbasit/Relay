import Foundation
import Testing
@testable import Relay

/// Cross-browser adapter contracts, not live Safari/Chrome qualification.
@MainActor
struct BrowserCompatibilityMatrixTests {
    @Test func directOpenRunsOnlyForAnExplicitPreDispatchCapabilityGap() async throws {
        var opens = 0
        let deadline = Date().addingTimeInterval(30)
        let result = try await BrowserAutomation.withDirectOpenFallback(deadline: deadline) {
            throw BrowserAutomation.DirectOpenFallback.unsupportedAddressControl
        } open: {
            opens += 1
            return ToolResult(summary: "Requested open", evidence: "Synthetic direct-open fixture", verified: false)
        }
        #expect(opens == 1)
        #expect(!result.verified)

        for failure in [RelayError.message("Address confirmation uncertain"), CancellationError()] as [any Error] {
            await #expect(throws: (any Error).self) {
                try await BrowserAutomation.withDirectOpenFallback(deadline: deadline) {
                    throw failure
                } open: {
                    opens += 1
                    return result
                }
            }
        }
        await #expect(throws: RelayError.self) {
            try await BrowserAutomation.withDirectOpenFallback(deadline: Date().addingTimeInterval(-1)) {
                throw BrowserAutomation.DirectOpenFallback.unavailableSafariTabSelection
            } open: {
                opens += 1
                return result
            }
        }
        #expect(opens == 1)
    }

    @Test func navigationRequiresEveryIdentityDimensionForBothAddressStyles() throws {
        let expected = try BrowserAutomation.validatedURL("http://127.0.0.1:49217/fixture/run")
        for address in [expected.absoluteString, "127.0.0.1:49217/fixture/run"] {
            for bits in 0..<8 {
                let window = bits & 1 != 0, tab = bits & 2 != 0, focus = bits & 4 != 0
                #expect(BrowserAutomation.documentMatchesReviewedNavigation(pageURL: expected.absoluteString,
                    title: "Relay browser qualification", addressURL: address, sameWindow: window,
                    sameNewTab: tab, ownsFocus: focus, expected: expected) == (bits == 7))
            }
        }
    }

    @Test func exactLocalFixtureCannotBeCertifiedByOtherPortTokenOrRedirect() throws {
        let expected = try BrowserAutomation.validatedURL("http://127.0.0.1:49217/fixture/run?q=one#marker")
        for actual in [
            "http://127.0.0.1:49218/fixture/run?q=one#marker",
            "http://localhost:49217/fixture/run?q=one#marker",
            "http://127.0.0.1:49217/fixture/other?q=one#marker",
            "http://127.0.0.1:49217/next/run?q=one#marker",
            "http://127.0.0.1:49217/fixture/run?q=two#marker",
            "http://127.0.0.1:49217/fixture/run?q=one#other"
        ] {
            #expect(!BrowserAutomation.matchesDestination(actual, expected: expected))
            #expect(!BrowserPageReader.snapshotIdentityMatches(sameProcess: true, sameWindow: true,
                sameTab: true, sameDocument: true, beforeURL: expected.absoluteString, afterURL: actual,
                beforeTitle: "Fixture", afterTitle: "Fixture", expected: expected))
        }
    }

    @Test func tabRoleCompatibilityDoesNotRelaxUniquenessOrCompleteness() {
        for role in ["AXRadioButton", "AXTab"] {
            for selectedIndex in [0, 50, 99] {
                let tabs = (0..<100).map {
                    BrowserAutomation.TabSelectionState(index: $0, role: role, value: $0 == selectedIndex, selected: nil)
                }
                #expect(BrowserAutomation.selectedTabIndex(explicit: [], tabs: tabs, traversalComplete: true) == selectedIndex)
                #expect(BrowserAutomation.selectedTabIndex(explicit: [selectedIndex], tabs: tabs, traversalComplete: false) == nil)
                #expect(BrowserAutomation.selectedTabIndex(explicit: [selectedIndex, selectedIndex], tabs: tabs, traversalComplete: true) == nil)
            }
        }
    }

    @Test func unicodeSnapshotBudgetAndLiteralLinksStayBoundedTogether() throws {
        let base = try BrowserAutomation.validatedURL("http://127.0.0.1:49217/fixture/run")
        let title = "Relay · Café 🌍 · مرحبا"
        let budget = BrowserPageReader.snapshotBudgets(url: base.absoluteString, title: title)
        let text = BrowserPageReader.boundedText([String(repeating: title + "\n", count: 1000)], maximumBytes: budget.text)
        #expect(text.utf8.count <= budget.text)
        #expect(!text.contains("�"))
        let link = try #require(BrowserPageReader.validatedLink(title: "Next · التالي", url: "/next/run?q=a%26b%3Dc", relativeTo: base))
        #expect(URLComponents(string: link.url)?.queryItems == [URLQueryItem(name: "q", value: "a&b=c")])
        #expect(budget.text + budget.links + base.absoluteString.utf8.count + title.utf8.count + 512 <= 12_000)
    }
}

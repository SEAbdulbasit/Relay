import Foundation
import Testing
@testable import Relay

@MainActor
struct BrowserPageReaderTests {
    @Test func linkSnapshotAcceptsOnlyBoundedHTTPDestinations() throws {
        let base = URL(string: "https://example.com/docs/page")!
        #expect(BrowserPageReader.validatedLink(title: "Next", url: "../next?q=123", relativeTo: base)?.url == "https://example.com/next?q=123")
        for url in ["", "javascript:alert(1)", "data:text/html,test", "file:///tmp/local", "https://user:password@example.com", "https://example.com/%0A", String(repeating: "a", count: 4097)] {
            #expect(BrowserPageReader.validatedLink(title: "Untrusted link", url: url, relativeTo: base) == nil)
        }
    }

    @Test func snapshotTextBudgetPreservesUnicodeAndExcludesControlBytes() {
        let text = BrowserPageReader.boundedText(["  Hello\u{0}\u{1}", "مرحبا 🌍"], maximumBytes: 100)
        #expect(text == "Hello\nمرحبا 🌍")
        let bounded = BrowserPageReader.boundedText([String(repeating: "🌍", count: 100)], maximumBytes: 17)
        #expect(bounded == String(repeating: "🌍", count: 4))
        #expect(!bounded.contains("�"))
        #expect(BrowserPageReader.boundedText(["Hello"], maximumBytes: 0).isEmpty)
    }

    @Test func linkLabelsRemainBoundedUntrustedData() throws {
        let base = URL(string: "https://example.com/")!
        let link = try #require(BrowserPageReader.validatedLink(title: String(repeating: "label ", count: 1000), url: "/next", relativeTo: base))
        #expect(link.title.utf8.count <= 512)
        #expect(link.url == "https://example.com/next")
    }
    @Test func selectedTabWindowDocumentAndDestinationMustRemainIdentical() {
        let expected = URL(string: "https://example.com/")!
        func matches(process: Bool = true, window: Bool = true, tab: Bool = true, document: Bool = true,
                     afterURL: String = "https://example.com/", afterTitle: String = "Example") -> Bool {
            BrowserPageReader.snapshotIdentityMatches(sameProcess: process, sameWindow: window, sameTab: tab,
                sameDocument: document, beforeURL: "https://example.com/", afterURL: afterURL,
                beforeTitle: "Example", afterTitle: afterTitle, expected: expected)
        }
        #expect(matches())
        #expect(!matches(process: false))
        #expect(!matches(window: false))
        #expect(!matches(tab: false))
        #expect(!matches(document: false))
        #expect(!matches(afterURL: "https://other.test/"))
        #expect(!matches(afterTitle: "Privacy error"))
        #expect(!matches(afterTitle: "Other title"))
    }

    @Test func combinedTextLinksAndMetadataCannotExceedSnapshotBudget() {
        for (url, title) in [("https://example.com/", "Example"), ("https://example.com/" + String(repeating: "a", count: 4000), String(repeating: "🌍", count: 2000))] {
            let budgets = BrowserPageReader.snapshotBudgets(url: url, title: title)
            let metadata = url.utf8.count + BrowserPageReader.boundedText([title], maximumBytes: 1024).utf8.count + 512
            #expect(budgets.text + budgets.links + metadata <= 12_000)
            #expect(budgets.text <= 8000)
            #expect(budgets.links <= 3000)
        }
    }

    @Test func safariContentGroupExceptionNeverCreatesOrRelaxRealTabSelection() {
        let safari = "SafariWindow?IsSecure=false&UUID=synthetic"
        #expect(BrowserPageReader.isUnselectedSafariContentGroup(windowIdentifier: safari,
            childRoles: ["AXScrollArea", "AXCollection"], complete: true))
        for identifier in ["ChromeWindow", "SafariWindow?IsSecure=true&UUID=private", "SafariWindow?IsSecure=false&UUID="] {
            #expect(!BrowserPageReader.isUnselectedSafariContentGroup(windowIdentifier: identifier,
                childRoles: ["AXCollection"], complete: true))
        }
        for roles in [["AXTab"], ["AXRadioButton", "AXGroup"], [""], Array(repeating: "AXGroup", count: 201)] {
            #expect(!BrowserPageReader.isUnselectedSafariContentGroup(windowIdentifier: safari,
                childRoles: roles, complete: true))
        }
        #expect(!BrowserPageReader.isUnselectedSafariContentGroup(windowIdentifier: safari,
            childRoles: ["AXCollection"], complete: false))
        #expect(BrowserAutomation.selectedTabIndex(explicit: nil, tabs: [], traversalComplete: true) == nil)
    }

    @Test func onlyPlainDestinationMismatchSuggestsReviewedNavigation() throws {
        let expected = try BrowserAutomation.validatedURL("http://127.0.0.1:49217/reading/run")
        #expect(BrowserPageReader.pageIdentityFailure(url: expected.absoluteString, title: "Fixture", expected: expected) == nil)
        let mismatch = try #require(BrowserPageReader.pageIdentityFailure(url: "http://127.0.0.1:49217/other/run", title: "Fixture", expected: expected))
        #expect(mismatch.contains("browser_navigate with destination review"))
        #expect(mismatch.contains("this read does not navigate"))
        for title in ["", "Privacy error", "Your connection is not private", "Authentication required"] {
            let failure = try #require(BrowserPageReader.pageIdentityFailure(url: "https://different.invalid/", title: title, expected: expected))
            #expect(!failure.contains("browser_navigate"))
        }
    }

}

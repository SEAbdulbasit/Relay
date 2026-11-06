import Foundation
import Testing
@testable import Relay

@MainActor
struct BrowserVerificationTests {
    @Test func cachedMatchingPageCannotCertifyDifferentTabOrWindow() throws {
        let expected = try BrowserAutomation.validatedURL("https://example.com/reviewed?q=one")
        func verified(window: Bool = true, tab: Bool = true, focus: Bool = true,
                      address: String = "https://example.com/reviewed?q=one",
                      page: String = "https://example.com/reviewed?q=one", title: String = "Example") -> Bool {
            BrowserAutomation.documentMatchesReviewedNavigation(pageURL: page, title: title,
                addressURL: address, sameWindow: window, sameNewTab: tab, ownsFocus: focus, expected: expected)
        }
        #expect(verified())
        #expect(!verified(window: false))
        #expect(!verified(tab: false))
        #expect(!verified(focus: false))
        #expect(!verified(address: "https://example.com/other"))
        #expect(!verified(page: "https://redirect.test/"))
        #expect(!verified(title: ""))
        #expect(!verified(title: "Your connection is not private"))
    }
    @Test func formattedAddressCanOmitSchemeOnlyWhenFullPageURLStillMatches() throws {
        let localhost = try BrowserAutomation.validatedURL("http://127.0.0.1:8765/")
        #expect(BrowserAutomation.documentMatchesReviewedNavigation(pageURL: localhost.absoluteString, title: "Local fixture",
            addressURL: "127.0.0.1:8765", sameWindow: true, sameNewTab: true, ownsFocus: true, expected: localhost))
        let expected = try BrowserAutomation.validatedURL("https://example.com/path?q=one")
        #expect(BrowserAutomation.documentMatchesReviewedNavigation(pageURL: expected.absoluteString, title: "Example",
            addressURL: "example.com/path?q=one", sameWindow: true, sameNewTab: true, ownsFocus: true, expected: expected))
        for address in ["other.test/path?q=one", "example.com/wrong?q=one", "example.com/path?q=two", "//example.com/path?q=one", "user@example.com/path?q=one", "example.com/path?q=one\n", "example.com/path with spaces?q=one", "http://example.com/path?q=one"] {
            #expect(!BrowserAutomation.documentMatchesReviewedNavigation(pageURL: expected.absoluteString, title: "Example",
                addressURL: address, sameWindow: true, sameNewTab: true, ownsFocus: true, expected: expected))
        }
        #expect(!BrowserAutomation.documentMatchesReviewedNavigation(pageURL: "http://example.com/path?q=one", title: "Example",
            addressURL: "example.com/path?q=one", sameWindow: true, sameNewTab: true, ownsFocus: true, expected: expected))
        #expect(!BrowserAutomation.documentMatchesReviewedNavigation(pageURL: "example.com/path?q=one", title: "Example",
            addressURL: "example.com/path?q=one", sameWindow: true, sameNewTab: true, ownsFocus: true, expected: expected))
        #expect(!BrowserAutomation.matchesDestination("example.com/path?q=one", expected: expected))
    }

    @Test func expiredBrowserActionsCannotResumeAfterSleep() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try BrowserAutomation.checkNavigationDeadline(start.addingTimeInterval(30), now: start)
        #expect(throws: (any Error).self) { try BrowserAutomation.checkNavigationDeadline(start.addingTimeInterval(30), now: start.addingTimeInterval(30)) }
        #expect(throws: (any Error).self) { try BrowserAutomation.checkNavigationDeadline(start.addingTimeInterval(30), now: start.addingTimeInterval(8 * 3600)) }
    }

    @Test func sameOriginFixtureLandingSuppliesReadbackWithoutCertifyingTheReviewedURL() throws {
        let reviewed = try BrowserAutomation.validatedURL("http://127.0.0.1:49217/redirect/fixture")
        let landing = "http://127.0.0.1:49217/next/fixture"
        func readback(page: String? = nil, address: String = "127.0.0.1:49217/next/fixture",
                      title: String = "Relay next page", window: Bool = true, tab: Bool = true,
                      focus: Bool = true) -> BrowserAutomation.LandingReadback? {
            BrowserAutomation.landingReadback(pageURL: page ?? landing, title: title, addressURL: address,
                sameWindow: window, sameNewTab: tab, ownsFocus: focus, expected: reviewed)
        }
        let candidate = try #require(readback())
        #expect(candidate.url == landing)
        #expect(!candidate.matchedReview)
        #expect(!candidate.result(browser: .safari).verified)
        #expect(candidate.result(browser: .safari).summary.contains(landing))
        #expect(readback(page: reviewed.absoluteString, address: reviewed.absoluteString)?.result(browser: .chrome).verified == true)
        #expect(readback(address: reviewed.absoluteString) == nil)
        #expect(readback(window: false) == nil)
        #expect(readback(tab: false) == nil)
        #expect(readback(focus: false) == nil)
        #expect(readback(title: "Sign in") == nil)
        #expect(readback(title: "   ") == nil)
        for rejected in ["http://localhost:49217/next/fixture", "http://127.0.0.1:49218/next/fixture",
                         "https://127.0.0.1:49217/next/fixture", landing + "?unexpected-token=secret", landing + "#new-fragment"] {
            #expect(readback(page: rejected, address: rejected) == nil)
        }
        let inbox = try BrowserAutomation.validatedURL("https://mail.google.com/mail/u/0/")
        let otherInbox = "https://mail.google.com/mail/u/1/"
        #expect(BrowserAutomation.landingReadback(pageURL: otherInbox, title: "Inbox", addressURL: otherInbox,
            sameWindow: true, sameNewTab: true, ownsFocus: true, expected: inbox) == nil)
    }
}

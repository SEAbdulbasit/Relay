import Foundation
import Testing
@testable import Relay

@MainActor
struct BrowserAutomationTests {
    @Test func browserSelectionIsExactAndUnambiguous() throws {
        #expect(try BrowserAutomation.validatedBrowser("  Google   CHROME ") == .chrome)
        #expect(try BrowserAutomation.validatedBrowser("com.apple.Safari") == .safari)
        for name in ["", "browser", "Chrome or Safari", "Chrome Canary", "com.google.Chrome.bad", "/Applications/Safari.app"] {
            #expect(throws: (any Error).self) { try BrowserAutomation.validatedBrowser(name) }
        }
    }

    @Test func searchQueryIsEncodedAsOneLiteralQueryItem() throws {
        let query = "صوت 🌍 & q=other + #? / 123"
        let url = try BrowserAutomation.searchURL(query: query)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "duckduckgo.com")
        #expect(components.queryItems == [URLQueryItem(name: "q", value: query)])
        #expect(components.fragment == nil)
        #expect(try BrowserAutomation.validatedQuery(String(repeating: "é", count: 512)).utf8.count == 1024)
        for bad in ["", "  ", "hello\nworld", "\thello", "hello\u{0}", String(repeating: "é", count: 513)] {
            #expect(throws: (any Error).self) { try BrowserAutomation.searchURL(query: bad) }
        }
    }

    @Test func navigationRejectsActiveSchemesCredentialsControlsAndAmbiguousURLs() throws {
        #expect(try BrowserAutomation.validatedURL("https://example.com/path?q=hello%20world").host == "example.com")
        for bad in ["", "example.com", "file:///tmp/test", "javascript:alert(1)", "data:text/html,test", "https:///path", "https://user:secret@example.com/", "https://user@example.com/", "https://example.com/a\nb", "https://example.com/%0D%0A", "https://example.com/a b", "https://example.com\\@evil.test", "https://example.com/" + String(repeating: "a", count: 4096)] {
            #expect(throws: (any Error).self) { try BrowserAutomation.validatedURL(bad) }
        }
    }

    @Test func verificationDoesNotTreatRedirectsOrDifferentQueriesAsExactDestination() throws {
        let expected = try BrowserAutomation.validatedURL("https://example.com/?q=123")
        #expect(BrowserAutomation.matchesDestination("https://EXAMPLE.com/?q=123", expected: expected))
        #expect(!BrowserAutomation.matchesDestination("https://other.test/?q=123", expected: expected))
        #expect(!BrowserAutomation.matchesDestination("http://example.com/?q=123", expected: expected))
        #expect(!BrowserAutomation.matchesDestination("https://example.com/?q=124", expected: expected))
        #expect(!BrowserAutomation.matchesDestination("https://example.com/?q=123#different", expected: expected))
        #expect(BrowserAutomation.isSecurityInterruption("Privacy error"))
        #expect(BrowserAutomation.isSecurityInterruption("Your connection is not private"))
        #expect(!BrowserAutomation.isSecurityInterruption("Example Domain"))
    }

    @Test func browserReviewBindsExactQueryAndBrowserBeforeDispatch() throws {
        let tools = MacTools()
        let original = ToolCall(id: "review", name: "search_web", arguments: ["query": .string("123"), "browser": .string("Chrome")])
        #expect(tools.reviewReason(for: original)?.contains("duckduckgo.com") == true)
        try tools.prepareReview(original)
        let changedQuery = ToolCall(id: original.id, name: original.name, arguments: ["query": .string("private other query"), "browser": .string("Chrome")])
        #expect(throws: (any Error).self) { try tools.authorize(changedQuery) }
        try tools.prepareReview(original)
        let changedBrowser = ToolCall(id: original.id, name: original.name, arguments: ["query": .string("123"), "browser": .string("Safari")])
        #expect(throws: (any Error).self) { try tools.authorize(changedBrowser) }
        try tools.prepareReview(original)
        tools.invalidateApprovals()
        #expect(throws: (any Error).self) { try tools.authorize(original) }
    }

    @Test func schemaRequiresBrowserAndRejectsArbitraryKeys() {
        for call in [
            ToolCall(name: "browser_navigate", arguments: ["url": .string("https://example.com")]),
            ToolCall(name: "search_web", arguments: ["query": .string("123"), "browser": .string("Chrome"), "keys": .string("Cmd+Q")])
        ] {
            #expect(throws: (any Error).self) { try ToolPolicy.validate(call, against: MacTools.definitions) }
        }
    }
}

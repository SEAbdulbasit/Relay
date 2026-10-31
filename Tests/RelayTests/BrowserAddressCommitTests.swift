import Testing
@testable import Relay

@MainActor
struct BrowserAddressCommitTests {
    @Test func addressEntryRequiresSuccessfulWritableQueryAndExactConfirmBeforePayload() {
        #expect(BrowserAddressCommit.entryConfirmationAction(settableQuerySucceeded: true,
            valueSettable: true, advertisedActions: ["AXConfirm"]) == "AXConfirm")
        // The API out-parameter cannot override query failure; read-only and missing
        // confirmation are separately unsupported, before any target URL is entered.
        for state in [(false, true), (false, false), (true, false)] {
            #expect(BrowserAddressCommit.entryConfirmationAction(settableQuerySucceeded: state.0,
                valueSettable: state.1, advertisedActions: ["AXConfirm"]) == nil)
        }
        let unsupported: [[String]?] = [nil, [], ["AXPress"], ["AXOpen"], ["AXConfirm", "AXConfirm"]]
        for actions in unsupported {
            #expect(BrowserAddressCommit.entryConfirmationAction(settableQuerySucceeded: true,
                valueSettable: true, advertisedActions: actions) == nil)
        }
    }

    @Test func exactAdvertisedConfirmationIsRequired() {
        #expect(BrowserAddressCommit.confirmationAction(advertisedActions: ["AXConfirm"]) == "AXConfirm")
        #expect(BrowserAddressCommit.confirmationAction(advertisedActions: ["AXShowMenu", "AXConfirm", "AXRaise"]) == "AXConfirm")
        let unsupported: [[String]?] = [nil, [], ["AXPress"], ["AXOpen"], ["AXConfirmButton"], ["axconfirm"], ["Return"], ["AXConfirm", "AXConfirm"]]
        for actions in unsupported {
            #expect(BrowserAddressCommit.confirmationAction(advertisedActions: actions) == nil)
        }
    }

    @Test func malformedOrOversizedActionDiscoveryFailsClosed() {
        for actions in [["AXConfirm", "AXPress\nReturn"], ["AXConfirm", "AXLabel: private"],
                        ["AXConfirm", "AX" + String(repeating: "a", count: 63)],
                        ["AXConfirm"] + (0..<32).map { "AXAction\($0)" }] {
            #expect(BrowserAddressCommit.confirmationAction(advertisedActions: actions) == nil)
        }
    }

    @Test func diagnosticDoesNotReturnArbitraryNativeContent() {
        let result = BrowserAddressCommit.diagnostic(advertisedActions: ["AXPress", "private URL https://example.invalid", "AXBad\nSecret", "AXConfirm", "AXPress"])
        #expect(result == "AXConfirm, AXPress")
        #expect(!result.contains("Secret"))
        #expect(!result.contains("https"))
        #expect(BrowserAddressCommit.diagnostic(advertisedActions: nil) == "unavailable")
        #expect(BrowserAddressCommit.diagnostic(advertisedActions: []) == "none qualified")
    }

    @Test func diagnosticRemainsBoundedWhenProviderReturnsManyActions() {
        let result = BrowserAddressCommit.diagnostic(advertisedActions: (0..<1000).map { "AXAction\($0)" })
        #expect(result.utf8.count <= 8 * 64 + 8 * 2 + 16)
        #expect(result.contains("bounded list"))
        #expect(!result.contains("AXAction999"))
    }
}

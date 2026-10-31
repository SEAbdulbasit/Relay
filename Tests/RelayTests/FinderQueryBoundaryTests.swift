import Foundation
import Testing
@testable import Relay

@MainActor
struct FinderQueryBoundaryTests {
    @Test func unicodeQueryLimitCountsUTF8BytesRatherThanCharacters() throws {
        let atLimit = String(repeating: "🌍", count: 64)
        #expect(try FinderAutomation.validatedQuery(atLimit) == atLimit)
        #expect(throws: (any Error).self) {
            try FinderAutomation.validatedQuery(atLimit + "a")
        }
        #expect(throws: (any Error).self) {
            try FinderAutomation.validatedQuery(String(repeating: "🌍", count: 65))
        }
    }

    @Test func filenamePunctuationRemainsLiteral() throws {
        for query in ["holiday 'final' (2).webm", "رحلة 🌍.webm", "$(not-a-command).webm", "a;b.webm"] {
            #expect(try FinderAutomation.validatedQuery(query) == query)
        }
    }

    @Test func embeddedKeyboardControlCharactersAreRejected() {
        for scalar in ["\t", "\r", "\u{1B}", "\u{7F}"] {
            #expect(throws: (any Error).self) {
                try FinderAutomation.validatedQuery("before" + scalar + "after.webm")
            }
        }
    }
}

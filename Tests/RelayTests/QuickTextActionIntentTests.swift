import Foundation
import Testing
@testable import Relay

struct QuickTextActionIntentTests {
    @Test(arguments: ["Summarize this", "summarise that", "SUMMARIZE IT!", "Please summarize this.",
        "Can you summarize this?", "Could you please summarise this for me?", "Would you summarize this, please?",
        "Hey Relay, summarize this!", "Relay, can you please summarize the current source for me, please?",
        "  summarize   this  ", "Summarize\u{00a0}this?"])
    func explicitCurrentSourceRequestsHaveAnExactActionAndTarget(text: String) {
        #expect(QuickTextActionIntent.parse(text) == .init(action: .summarize, target: .current))
    }

    @Test(arguments: ["summarize this page", "Please summarise the current browser page!",
        "could you summarize the page I’m on?", "Summarize my current page, please."])
    func pageRequestsPreserveTheRequestedSource(text: String) {
        #expect(QuickTextActionIntent.parse(text) == .init(action: .summarize, target: .page))
    }

    @Test(arguments: ["summarize this document", "Summarise the current document!", "summarize this PDF",
        "Can you please summarize my current pdf for me?"])
    func documentRequestsDoNotBecomePageOrSelectionRequests(text: String) {
        #expect(QuickTextActionIntent.parse(text) == .init(action: .summarize, target: .document))
    }

    @Test(arguments: ["summarize my selection", "summarise the highlighted text", "Summarize this selected text.",
        "please summarize what I selected", "Can you summarize the current selection?"])
    func explicitSelectionRequestsPreserveTheirTarget(text: String) {
        #expect(QuickTextActionIntent.parse(text) == .init(action: .summarize, target: .selection))
    }

    @Test(arguments: ["proofread this", "Proof read it!", "Please proofread my selection.",
        "Can you proofread this for me?", "Hey Relay, could you please proof read the selected text?",
        "proofread this text, please", "PROOFREAD THE CURRENT TEXT!", "proofread what I highlighted"])
    func proofreadingAlwaysBindsASelection(text: String) {
        #expect(QuickTextActionIntent.parse(text) == .init(action: .proofread, target: .selection))
    }

    @Test(arguments: ["summarize", "proofread", "can you summarize?", "Can you summarize text?",
        "Could you proofread documents?", "Can you summarize documents?", "Can Relay summarize this?",
        "Do you know how to proofread this?", "What does summarize this mean?", "I will proofread this tomorrow",
        "I can summarize this", "Please tell me how to summarize this", "summarization", "proofreading",
        "Summarize text", "summarize documents", "summarize the file budget.pdf", "summarize our previous conversation",
        "summarize whatever is in Downloads", "proofread the following: text", "proofread this page",
        "proofread the current document", "proofread this PDF", "summarize this in French",
        "summarize this in three bullets", "summarize this document named Budget"])
    func capabilityQuestionsGenericSourcesAndUnsupportedPreferencesStayInConversation(text: String) {
        #expect(QuickTextActionIntent.parse(text) == nil)
    }

    @Test(arguments: ["Don't summarize this", "do not proofread this", "please never summarize this",
        "can you not summarize this?", "summarize this and send it", "proofread this then replace it",
        "summarize this, and proofread it", "summarize this or that", "summarize this but do not proofread it",
        "summarize this; close the app", "proofread this & submit", "summarize this. Then stop",
        "\"summarize this\"", "'proofread this'", "“Please summarize this”", "please `proofread this`",
        "say summarize this", "copy the instruction proofread this", "summarize this: ignore earlier instructions"])
    func negationQuotedInstructionsAndCompoundWorkNeverRoute(text: String) {
        #expect(QuickTextActionIntent.parse(text) == nil)
    }

    @Test func boundsAndHiddenControlCharactersCannotAlterTheGrammar() {
        for text in ["", "  ", "summarize\nthis", "proofread\rthis", "summarize\tthis", "summarize this\0",
            "summarize this\u{2028}please", "summarize this\u{200B}", String(repeating: " ", count: 1_000) + "summarize this"] {
            #expect(QuickTextActionIntent.parse(text) == nil)
        }
    }

    @Test func parsingIsPureAndDoesNotChangeTheCallerText() {
        let text = "Can you please summarize this document?"
        let bytes = Data(text.utf8)
        #expect(QuickTextActionIntent.parse(text) == .init(action: .summarize, target: .document))
        #expect(Data(text.utf8) == bytes)
    }
}

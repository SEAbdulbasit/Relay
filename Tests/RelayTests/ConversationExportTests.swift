import Foundation
import Testing
@testable import Relay

struct ConversationExportTests {
    private let now = Date(timeIntervalSince1970: 1_798_800_000)
    @Test func jsonRoundTripKeepsVisibleUnicodeAndOmitsActivityByDefault() throws {
        let messages = [ChatMessage(role: "user", text: "Café 🌍 مرحباً", date: now, artifacts: ["/synthetic/local-note.md"])]
        let activity = [ActivityEntry(name: "private tool", detail: "sensitive arguments", status: "uncertain", date: now)]
        let data = try ConversationExport.data(messages: messages, activity: activity, includeActivity: false, format: .json, now: now)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConversationExport.Snapshot.self, from: data)
        #expect(decoded.version == 1)
        #expect(decoded.messages.first?.text == messages[0].text)
        #expect(decoded.messages.first?.artifacts == messages[0].artifacts)
        #expect(decoded.activity == nil)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set(["version", "exportedAt", "messages"]))
        #expect(!String(decoding: data, as: UTF8.self).contains("sensitive arguments"))
    }
    @Test func activityRequiresExplicitInclusionAndPreservesUncertainStatus() throws {
        let activity = [ActivityEntry(name: "click", detail: "No independent effect observed", status: "uncertain", date: now)]
        let data = try ConversationExport.data(messages: [], activity: activity, includeActivity: true, format: .json, now: now)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ConversationExport.Snapshot.self, from: data)
        #expect(snapshot.activity?.first?.status == "uncertain")
        #expect(snapshot.messages.isEmpty)
    }
    @Test func markdownContainsSourceTextInsideUnbreakableFences() throws {
        let text = "First\n```\n<script>alert(1)</script>\n````\n# forged heading"
        let message = ChatMessage(role: "assistant", text: text, date: now)
        let data = try ConversationExport.data(messages: [message], activity: [], includeActivity: false, format: .markdown, now: now)
        let result = String(decoding: data, as: UTF8.self)
        #expect(result.contains("`````text\n" + text + "\n`````"))
        #expect(result.contains("Clear-text visible history"))
        #expect(!result.contains("## Activity snapshot"))
    }
    @Test func invalidDatesAndExcessiveReferencesAreRefused() throws {
        #expect(throws: (any Error).self) {
            try ConversationExport.data(messages: [], activity: [], includeActivity: false, format: .json, now: .init(timeIntervalSinceReferenceDate: .infinity))
        }
        #expect(throws: (any Error).self) {
            try ConversationExport.data(messages: [.init(role: "user", text: "", date: now, artifacts: Array(repeating: "", count: 101))], activity: [], includeActivity: false, format: .markdown, now: now)
        }
    }
    @Test func oversizedInputIsRejectedRatherThanTruncated() throws {
        let message = ChatMessage(role: "user", text: String(repeating: "a", count: ConversationExport.maximumInputBytes + 1), date: now)
        #expect(throws: (any Error).self) {
            try ConversationExport.data(messages: [message], activity: [], includeActivity: false, format: .json, now: now)
        }
    }
    @Test func emptyMarkdownExportIsAnExplicitEmptySnapshot() throws {
        let data = try ConversationExport.data(messages: [], activity: [], includeActivity: false, format: .markdown, now: now)
        #expect(String(decoding: data, as: UTF8.self).contains("No visible messages."))
    }
}

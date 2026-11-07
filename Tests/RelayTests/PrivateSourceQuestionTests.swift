import Foundation
import Testing
@testable import Relay

@MainActor
struct PrivateSourceQuestionTests {
    @Test func selectedSourceAnswerIsToolFreeAndNeverEntersSavedChat() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "state.json")
        let source = NativePersonalSources { _, _ in
            NativePersonalSourceBatch(items: [.init(id: "1", title: "Test note", sender: nil,
                text: "Only the synthetic source contains MARMOT-351.", textLimited: false)], skipped: 0)
        }
        await source.captureSelection(.notes, requestPermission: false)
        let history = AssistantConversationHistory(stateURL: path)
        let store = AssistantStore(persistenceURL: path, complete: { messages, tools, _ in
            #expect(tools.isEmpty)
            #expect(messages.last?.content.contains("MARMOT-351") == true)
            return ModelReply(content: "Test note says MARMOT-351.", toolCalls: [])
        }, conversationHistory: history, nativeSources: source)
        store.saveConfiguration()
        let answer = try await store.askNativeSource(.notes, question: "What is the test token?")
        #expect(answer == "Test note says MARMOT-351.")
        #expect(store.messages.isEmpty)
        #expect(store.activity.isEmpty)
        #expect(try !String(contentsOf: try #require(history.preferencesURL), encoding: .utf8).contains("MARMOT-351"))
        let core = try await history.journalForTesting(), scope = try await core.scope()
        #expect(try await core.page(expectedScope: scope).records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        source.forget(.notes)
        await #expect(throws: (any Error).self) { try await store.askNativeSource(.notes, question: "What is the token?") }
    }
}

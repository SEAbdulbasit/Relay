import Foundation
import Testing
@testable import Relay

@Suite(.serialized) @MainActor struct FileReadPriorPublicationTests {
    @Test func anAlreadyAdmittedVisibleFactRemainsReviewableWhileANewTaskCannotReuseItsOldBody() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-prior-visible-read-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appending(path: "source.txt"), a = "PREVIOUSLY_ADMITTED_A_" + UUID().uuidString
        let b = "NEW_UNREAD_B_" + UUID().uuidString
        try Data(a.utf8).write(to: file)
        let history = AssistantConversationHistory(stateURL: root.appending(path: "state.json"))
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5))
        let legacyWorker = SelectedFileProofWorker(timeout: .seconds(5))
        let tools = MacTools(), grants = [ScopeGrant(path: root.path)]; tools.grants = grants
        var turns = 0, reads = 0
        let store = AssistantStore(persistenceURL: nil, complete: { input,_,_ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [.init(id: "legitimately-visible-read", name: "read_file", arguments: ["path": .string(file.path)])]) }
            if turns == 2 { #expect(input.contains { $0.content.contains(a) }); return .init(content: "The current read is ready.", toolCalls: []) }
            #expect(turns == 3 && !input.contains { $0.content.contains(a) || $0.content.contains(b) })
            return .init(content: "New task acknowledged without reusing prior source content.", toolCalls: [])
        }, conversationHistory: history, continuationProofWorker: legacyWorker, executeFileRead: { call, scope in
            reads += 1; return try await tools.execute(call, fileReadScope: scope, fileReadWorker: worker)
        }, fileReadWorker: worker)
        do {
            await store.waitForConversationTaskToSettle(); store.grants = grants
            store.draft = "Read the selected file and report admitted evidence."; store.send()
            await store.waitForConversationTaskToSettle()
            #expect(turns == 2 && reads == 1)
            #expect(store.activity.contains { $0.name == "read_file" && $0.detail.contains(a) })
            let displayed = store.messages.map(\.text)
            #expect(displayed.contains { $0.contains(a) })
            try Data(b.utf8).write(to: file)
            #expect(store.messages.map(\.text) == displayed)
            store.draft = "Give a source-free acknowledgment for a new task."; store.send()
            await store.waitForConversationTaskToSettle()
            #expect(turns == 3 && reads == 1)
            #expect(store.activity.contains { $0.name == "read_file" && $0.detail.contains(a) })
            #expect(store.messages.contains { $0.text.contains(a) })
            #expect(try Data(contentsOf: file) == Data(b.utf8))
            store.stop(); await store.waitForConversationTaskToSettle(); await worker.drain(); await legacyWorker.drain()
            try await history.close(); try FileManager.default.removeItem(at: root)
        } catch {
            store.stop(); await store.waitForConversationTaskToSettle(); await worker.drain(); await legacyWorker.drain()
            try? await history.close(); try? FileManager.default.removeItem(at: root); throw error
        }
    }
}

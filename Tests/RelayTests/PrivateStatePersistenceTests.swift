import Foundation
import Testing
@testable import Relay

@MainActor
struct PrivateStatePersistenceTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func visibleHistoryKnowledgeAndPreferencesPersistPrivatelyAndRestore() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("chosen.md")
        try Data("Private synthetic source Café 🌍".utf8).write(to: source)
        let state = root.appendingPathComponent("state.json")
        let history = AssistantConversationHistory(stateURL: state)
        let store = AssistantStore(persistenceURL: state, complete: { _, _, _ in .init(content: "Synthetic private reply", toolCalls: []) }, conversationHistory: history)
        store.grants = [.init(path: source.path)]
        store.addMemory("Synthetic approved preference")
        await store.knowledge.index(grants: store.grants)
        store.writingProfile.preferredTone = "Synthetic direct style"
        try store.writingProfile.save()
        store.setSuggestionsEnabled(true)
        try store.preparation.setTime(hour: 9, minute: 0)
        store.draft = "Synthetic private question"; store.send()
        await store.waitForConversationTaskToSettle()
        for name in ["state.json.preferences-v2.json", "knowledge.json", "writing-profile.json", "suggestions.json", "preparation-schedule.json"] {
            let url = root.appendingPathComponent(name)
            let metadata = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((metadata[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) is [String: Any])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".relay-private-write-") }.isEmpty)
        let journalDirectory = state.deletingLastPathComponent().appendingPathComponent(state.lastPathComponent + ".conversation-v1")
        let journalPermissions = try FileManager.default.attributesOfItem(atPath: journalDirectory.path)
        #expect((journalPermissions[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        for name in ["Conversation.sqlite", "Conversation.sqlite-wal", "Conversation.sqlite-shm"] {
            let metadata = try FileManager.default.attributesOfItem(atPath: journalDirectory.appendingPathComponent(name).path)
            #expect((metadata[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        #expect(!FileManager.default.fileExists(atPath: state.path))
        try await history.close()
        let restored = AssistantStore(persistenceURL: state)
        await restored.waitForConversationTaskToSettle()
        #expect(restored.messages.contains { $0.text.hasPrefix("Synthetic private reply") })
        #expect(restored.memories.first?.text == "Synthetic approved preference")
        #expect(restored.knowledge.records.first?.text == "Private synthetic source Café 🌍")
        #expect(restored.writingProfile.contextDescription().contains("Synthetic direct style"))
        #expect(!restored.preparation.enabled)
    }
    @Test func genericStateCapCanExceedExportCapWithoutWideningExport() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 65, count: ConversationExportWriter.maximumBytes + 1)
        let state = root.appendingPathComponent("large-state.json")
        try LocalPrivateFileWriter.write(data: data, to: state, maximumBytes: 20_971_520)
        #expect(try state.resourceValues(forKeys: [.fileSizeKey]).fileSize == data.count)
        let export = root.appendingPathComponent("export.json")
        #expect(throws: ConversationExportWriteError.outputTooLarge) { try ConversationExportWriter.write(data: data, to: export) }
        #expect(!FileManager.default.fileExists(atPath: export.path))
    }
}

import Foundation
import Testing
@testable import Relay

@MainActor
struct GeneratedKnowledgeVaultTests {
    @Test func reloadSkipsUnchangedSourcesAndLinksOnlyActualProvenance() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("First line is not selected.\nCafé 🌍 ships Friday; [[Unrelated]].", named: "launch.md")
        try fixture.write("Unrelated fixture text.", named: "Unrelated.md")
        await fixture.index()
        let launch = try #require(fixture.knowledge.records.first { $0.title == "launch.md" })
        var calls = 0
        await fixture.generate { messages in
            calls += 1
            let prompt = try #require(messages.last?.content)
            return self.reply(prompt.contains("ships Friday") ? "{\"highlights\":[2]}" : "{\"highlights\":[1]}")
        }
        #expect(calls == 2)
        let note = try #require(fixture.vault.notes.first { $0.sourcePath == launch.sourcePath })
        #expect(note.highlights == ["Café 🌍 ships Friday; [[Unrelated]]."])
        let path = fixture.cache.appending(path: note.id)
        let markdown = try String(contentsOf: path, encoding: .utf8)
        #expect(markdown.contains(launch.sourcePath))
        #expect(markdown.contains(launch.contentHash))
        #expect(markdown.contains("~~~text\nCafé 🌍 ships Friday; [[Unrelated]].\n~~~"))
        #expect(!markdown.contains("First line is not selected."))
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let reopened = GeneratedKnowledgeVault(directoryURL: fixture.cache)
        await reopened.generate(records: fixture.knowledge.records, isCurrent: { _ in true }) { _ in
            Issue.record("The unchanged source should have used its durable checkpoint.")
            return self.reply("{\"highlights\":[1]}")
        }
        #expect(reopened.notes == fixture.vault.notes)

        let copyURL = try #require(URL(string: "relay-vault://note/highlights-copy"))
        let graph = SkyGraph.build(records: fixture.knowledge.records,
                                   customNotes: [copyURL: (title: "Editable copy", domain: "Your Notes", body: note.markdownBody)],
                                   generatedNotes: reopened.notes)
        let generated = try #require(graph.nodes.firstIndex { $0.url == note.graphURL })
        let actualSource = try #require(graph.nodes.firstIndex { $0.url == note.sourceURL })
        let unrelated = try #require(graph.nodes.firstIndex { $0.title == "Unrelated.md" })
        #expect(graph.adjacency[generated].contains(actualSource))
        #expect(!graph.adjacency[generated].contains(unrelated))
        let copy = try #require(graph.nodes.firstIndex { $0.url == copyURL })
        #expect(!graph.adjacency[copy].contains(unrelated))
    }

    @Test func changedDeletedAndRevokedSourcesRemoveOnlyManagedNotes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Source before change", named: "change.txt")
        try fixture.write("Source before deletion", named: "delete.txt")
        await fixture.index()
        await fixture.generate { _ in self.reply("{\"highlights\":[1]}") }
        let initial = fixture.vault.notes
        #expect(initial.count == 2)
        let unrelated = fixture.cache.appending(path: "Independent note.md")
        try Data("Keep this note".utf8).write(to: unrelated)
        try fixture.write("Source after change", named: "change.txt")
        try FileManager.default.removeItem(at: fixture.sources.appending(path: "delete.txt"))
        fixture.knowledge.purgeStale(grants: fixture.grants)
        #expect(fixture.vault.notes.isEmpty)
        #expect(initial.allSatisfy { !FileManager.default.fileExists(atPath: fixture.cache.appending(path: $0.id).path) })
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "Keep this note")

        await fixture.index()
        await fixture.generate { _ in self.reply("{\"highlights\":[1]}") }
        let refreshed = try #require(fixture.vault.notes.first)
        #expect(refreshed.highlights == ["Source after change"])
        fixture.knowledge.purgeStale(grants: [])
        #expect(fixture.vault.notes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.appending(path: refreshed.id).path))
    }

    @Test func staleInFlightSourceAndUntrustedModelOutputNeverBecomeNotes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Stable facts", named: "a.txt")
        try fixture.write("Will change during inference", named: "b.txt")
        await fixture.index()
        await fixture.generate { messages in
            if messages.last?.content.contains("Will change") == true {
                try fixture.write("Changed during model call", named: "b.txt")
                return self.reply("{\"highlights\":[1]}")
            }
            return self.reply("{\"highlights\":[19],\"invented\":\"Do not save this.\"}")
        }
        #expect(fixture.vault.notes.isEmpty)
        #expect(fixture.knowledge.records.map(\.title) == ["a.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).isEmpty)
    }

    @Test func completedCheckpointsSurviveCancellationAndExternalEditsArePreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("First source", named: "a.txt")
        try fixture.write("Second source", named: "b.txt")
        await fixture.index()
        var calls = 0
        await fixture.generate { _ in
            calls += 1
            if calls == 2 { fixture.vault.cancel() }
            return self.reply("{\"highlights\":[1]}")
        }
        #expect(calls == 2)
        #expect(fixture.vault.notes.map(\.sourceTitle) == ["a.txt"])
        let completed = try #require(fixture.vault.notes.first)
        let file = fixture.cache.appending(path: completed.id)
        try Data("User changed a managed file outside Relay".utf8).write(to: file)

        await fixture.generate { messages in
            #expect(messages.last?.content.contains("Second source") == true)
            return self.reply("{\"highlights\":[1]}")
        }
        #expect(fixture.vault.notes.map(\.sourceTitle) == ["b.txt"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "User changed a managed file outside Relay")
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_GENERATED_KNOWLEDGE_LIVE"] == "1"),
        .timeLimit(.minutes(5))
    )
    func realLocalModelProducesAProvenanceLinkedMarkdownNote() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let selected = try #require(ProcessInfo.processInfo.environment["RELAY_LOCAL_MODEL_PATH"])
        try fixture.write("The Marigold workshop starts Monday at 10:00.\nParticipants need a laptop and charger.\nThe optional room tour follows at 11:30.", named: "workshop.md")
        let store = AssistantStore(persistenceURL: fixture.root.appending(path: "state.json"))
        store.configuration.modelPath = selected
        store.configuration.computeBackend = "cpu"
        store.grants = fixture.grants
        await store.knowledge.index(grants: store.grants)
        await store.refreshModels()
        try #require(store.actionsReady, Comment(rawValue: store.modelStatus))
        await store.generateKnowledgeNotes()
        let note = try #require(store.generatedKnowledge.notes.first, Comment(rawValue: store.generatedKnowledge.status))
        let source = try #require(store.knowledge.records.first)
        #expect(note.sourceHash == source.contentHash)
        #expect(note.highlights.allSatisfy(source.text.contains))
        #expect(note.markdownBody.contains("Marigold") || note.markdownBody.contains("laptop"))
    }

    private func reply(_ content: String) -> ModelReply { .init(content: content, toolCalls: []) }

    @MainActor
    private struct Fixture {
        let root: URL
        let sources: URL
        let cache: URL
        let knowledge = LocalKnowledge(persistenceURL: nil)
        let vault: GeneratedKnowledgeVault
        var grants: [ScopeGrant] { [.init(path: sources.path)] }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "relay-generated-\(UUID().uuidString)", directoryHint: .isDirectory)
            sources = root.appending(path: "sources", directoryHint: .isDirectory)
            cache = root.appending(path: "generated", directoryHint: .isDirectory)
            vault = GeneratedKnowledgeVault(directoryURL: cache)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            knowledge.onRecordsChanged = { [vault] in vault.reconcile(records: $0) }
        }

        func write(_ text: String, named filename: String) throws {
            try Data(text.utf8).write(to: sources.appending(path: filename), options: .atomic)
        }

        func index() async { await knowledge.index(grants: grants) }

        func generate(_ complete: @escaping ([ModelMessage]) async throws -> ModelReply) async {
            await vault.generate(records: knowledge.records,
                                 isCurrent: { knowledge.revalidate($0, grants: grants) }, complete: complete)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

import Foundation
import Testing
@testable import Relay

@MainActor
struct CrossSourceKnowledgeTests {
    @Test func onlyExplicitCanonicalEntityLinksJoinSourcesAndInputScopeStaysBounded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("[[Project: Café 🌍|Launch]]\nThe workshop begins Monday at 10:00.", name: "a.md")
        try fixture.write("[[project: CAFE\u{301} 🌍]]\nParticipants need a laptop and charger.", name: "b.md")
        try fixture.write("Café 🌍 is mentioned without an explicit relationship. UNSELECTED_SCOPE_SENTINEL", name: "unlinked.txt")
        try fixture.write("```\n[[Project: False]]\n```\n`[[Person: False]]`", name: "code.md")
        await fixture.index()
        let entities = CrossSourceKnowledge.entities(in: fixture.knowledge.records)
        #expect(entities.count == 1)
        let entity = try #require(entities.first)
        #expect(entity.sourcePaths.count == 2)
        let input = try CrossSourceKnowledge.input(entityURL: entity.id, records: fixture.knowledge.records)
        #expect(input.sources.count == 2)
        #expect(input.messages.allSatisfy { !$0.content.contains("UNSELECTED_SCOPE_SENTINEL") })
        #expect(input.candidates.allSatisfy { $0.quote.utf8.count <= 240 })
        await fixture.consolidate(entity.id) { messages in
            #expect(messages.allSatisfy { !$0.content.contains("UNSELECTED_SCOPE_SENTINEL") })
            return fixture.reply(for: input)
        }
        let draft = try #require(fixture.vault.consolidationDraft)
        #expect(Set(draft.excerpts.map(\.sourceIndex)).count == 2)
        for candidate in draft.excerpts {
            let source = try #require(fixture.knowledge.records.first { draft.revisions[candidate.sourceIndex].matches($0) })
            #expect(source.text.contains(candidate.quote))
            #expect(draft.markdownBody.contains(candidate.quote))
            #expect(draft.markdownBody.contains(source.contentHash))
        }
        #expect(draft.markdownBody.contains("historical snapshot"))
        #expect(!FileManager.default.fileExists(atPath: fixture.notesDirectory.path), "Model completion must not write an editable note.")
    }

    @Test func duplicateSourceTitlesHaveExactBacklinksThatDisappearOnRevisionChangeAndRevocation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        await fixture.index()
        // Duplicate titles are possible across selected source directories.
        let records = fixture.knowledge.records.map { record in
            KnowledgeRecord(sourcePath: record.sourcePath, title: "Duplicate.md", text: record.text,
                modifiedAt: record.modifiedAt, contentHash: record.contentHash, byteCount: record.byteCount)
        }
        let input = try fixture.input(records)
        let draft = try input.draft(from: fixture.reply(for: input))
        let noteURL = try #require(URL(string: "relay-vault://note/cross-source-copy"))
        func graph(_ sources: [KnowledgeRecord]) -> SkyGraph {
            SkyGraph.build(records: sources, customNotes: [noteURL: (title: "Editable brief", domain: "Your Notes", body: draft.markdownBody)])
        }
        let linked = graph(records).linkedNodes(from: noteURL).filter(\.url.isFileURL)
        #expect(Set(linked.map(\.url.path)) == Set(records.map(\.sourcePath)))
        let changed = records.enumerated().map { index, record in
            index == 0 ? KnowledgeRecord(sourcePath: record.sourcePath, title: record.title, text: record.text + " changed",
                modifiedAt: record.modifiedAt, contentHash: record.contentHash, byteCount: record.byteCount) : record
        }
        #expect(graph(changed).linkedNodes(from: noteURL).filter(\.url.isFileURL).map(\.url.path) == [records[1].sourcePath])
        #expect(graph([]).linkedNodes(from: noteURL).allSatisfy { !$0.url.isFileURL })
    }

    @Test func sourceScopeGrowthAndSingleSourceEntitiesRefuseBeforeInference() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        await fixture.index()
        let input = try fixture.input()
        try fixture.write("[[Project: Marigold]]\nNewly indexed source, never shown in the scope review.", name: "c.md")
        await fixture.index()
        var calls = 0
        await fixture.vault.consolidate(entityURL: input.entity.id, records: fixture.knowledge.records,
            expectedSourcePaths: input.entity.sourcePaths, isCurrent: { _ in true }) { _ in
                calls += 1
                return fixture.reply(for: input)
            }
        #expect(calls == 0 && fixture.vault.consolidationDraft == nil)
        #expect(throws: RelayError.self) {
            try CrossSourceKnowledge.input(entityURL: input.entity.id, records: Array(fixture.knowledge.records.prefix(1)))
        }
    }

    @Test(arguments: ["single-source", "unknown-id", "duplicate-id", "tool-call"])
    func invalidCitationSelectionsNeverBecomeDrafts(failure: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        await fixture.index()
        let input = try fixture.input()
        await fixture.consolidate(input.entity.id) { _ in
            switch failure {
            case "single-source": return .init(content: "{\"highlights\":[1]}", toolCalls: [])
            case "unknown-id": return .init(content: "{\"highlights\":[1,999]}", toolCalls: [])
            case "duplicate-id": return .init(content: "{\"highlights\":[1,1]}", toolCalls: [])
            default: return .init(content: fixture.reply(for: input).content, toolCalls: [.init(name: "write_file", arguments: [:])])
            }
        }
        #expect(fixture.vault.consolidationDraft == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.notesDirectory.path))
    }

    @Test(arguments: ["text", "hash", "bytes", "title", "coverage", "modified", "revoked"])
    func pendingAndReadyDraftsInvalidateOnExactSourceRevisionChange(change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        await fixture.index()
        let input = try fixture.input()
        await fixture.consolidate(input.entity.id) { _ in
            let changed = fixture.changedRecords(change)
            fixture.vault.reconcile(records: changed)
            return fixture.reply(for: input)
        }
        #expect(fixture.vault.consolidationDraft == nil, "A late model result must not publish after source reconciliation.")
        await fixture.consolidate(input.entity.id) { _ in fixture.reply(for: input) }
        let ready = try #require(fixture.vault.consolidationDraft)
        #expect(!ready.isCurrent(records: fixture.changedRecords(change), isCurrent: { _ in true }))
        fixture.vault.reconcile(records: fixture.changedRecords(change))
        #expect(fixture.vault.consolidationDraft == nil)
    }

    @Test(arguments: ["stop", "dismiss", "caller"])
    func cancellationAndDismissalFenceLateResultsAndKeepInferenceSerialized(mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        await fixture.index()
        let input = try fixture.input()
        var continuation: CheckedContinuation<ModelReply, Never>?
        var calls = 0
        let pending = Task { await fixture.consolidate(input.entity.id) { _ in
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        } }
        for _ in 0..<1_000 where continuation == nil { await Task.yield() }
        let complete = try #require(continuation)
        if mode == "dismiss" { fixture.vault.dismissConsolidation() }
        else if mode == "caller" { pending.cancel() }
        else { fixture.vault.cancel() }
        #expect(fixture.vault.consolidationDraft == nil && fixture.vault.isGenerating)
        await fixture.consolidate(input.entity.id) { _ in calls += 1; return fixture.reply(for: input) }
        #expect(calls == 1)
        complete.resume(returning: fixture.reply(for: input))
        await pending.value
        #expect(!fixture.vault.isGenerating && fixture.vault.consolidationDraft == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.notesDirectory.path))
    }

    @Test func alreadyCancelledCallerNeverStartsInference() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        await fixture.index()
        let input = try fixture.input()
        var calls = 0
        let operation = Task { await fixture.consolidate(input.entity.id) { _ in
            calls += 1
            return fixture.reply(for: input)
        } }
        operation.cancel()
        await operation.value
        #expect(calls == 0 && fixture.vault.consolidationDraft == nil && !fixture.vault.isGenerating)
    }

    @Test(arguments: ["file", "grant"])
    func liveSourceRevalidationRejectsDiskOrGrantChangesDuringInference(change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        await fixture.index()
        let input = try fixture.input()
        var grants = fixture.grants
        await fixture.vault.consolidate(entityURL: input.entity.id, records: fixture.knowledge.records,
            expectedSourcePaths: input.entity.sourcePaths,
            isCurrent: { fixture.knowledge.revalidate($0, grants: grants) }) { _ in
                if change == "file" { try fixture.write("Source changed during model inference.", name: "a.md") }
                else { grants = [] }
                return fixture.reply(for: input)
            }
        #expect(fixture.vault.consolidationDraft == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.notesDirectory.path))
    }

    @Test func revokedAtSaveNeverWritesAndReviewedSaveIsOneUseWithoutOverwritingEditedSnapshots() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        await fixture.index()
        var input = try fixture.input()
        await fixture.consolidate(input.entity.id) { _ in fixture.reply(for: input) }
        let revoked = try #require(fixture.vault.consolidationDraft)
        #expect(throws: RelayError.self) {
            try fixture.vault.saveConsolidationDraft(id: revoked.id, title: revoked.title, body: revoked.markdownBody,
                records: fixture.knowledge.records, isCurrent: { _ in false }) { _, _ in
                    Issue.record("A revoked review must not call the Markdown writer.")
                    throw CancellationError()
                }
        }
        await fixture.consolidate(input.entity.id) { _ in fixture.reply(for: input) }
        let approved = try #require(fixture.vault.consolidationDraft)
        let first = try fixture.saveDraft()
        #expect(throws: RelayError.self) {
            try fixture.vault.saveConsolidationDraft(id: approved.id, title: approved.title, body: approved.markdownBody,
                records: fixture.knowledge.records, isCurrent: { _ in true }) {
                    try fixture.manager.saveNote(title: $0, body: $1)
                }
        }
        let edited = try fixture.manager.saveNote(title: first.title, body: first.body + "\n\nMy independent edit — e\u{301} 🌍.", replacing: first)
        let savedBytes = try Data(contentsOf: edited.url)
        try fixture.write("[[Project: Marigold]]\nThe workshop now begins Tuesday at 11:00.", name: "a.md")
        await fixture.index()
        fixture.vault.reconcile(records: [])
        #expect(try Data(contentsOf: edited.url) == savedBytes)
        input = try fixture.input()
        await fixture.consolidate(input.entity.id) { _ in fixture.reply(for: input) }
        let second = try fixture.saveDraft()
        #expect(second.url != edited.url)
        #expect(try Data(contentsOf: edited.url) == savedBytes)
        #expect(try fixture.manager.loadNotes().count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"] != nil), .timeLimit(.minutes(5)))
    func actualGemmaSelectsTwoSyntheticSourcesAndProducesExactCitedMarkdown() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"])
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        await fixture.index()
        let input = try fixture.input()
        let client = LocalModelClient()
        defer { client.unload() }
        let configuration = ModelConfiguration(modelPath: path, computeBackend: "cpu", model: "Gemma 4 E2B")
        var response = ""
        await fixture.consolidate(input.entity.id) { messages in
            let reply = try await client.complete(messages: messages, tools: [], configuration: configuration)
            response = reply.content
            return reply
        }
        let draft = try #require(fixture.vault.consolidationDraft, Comment(rawValue: "Synthetic Gemma response: " + response))
        #expect(Set(draft.excerpts.map(\.sourceIndex)).count >= 2)
        #expect(draft.excerpts.allSatisfy { candidate in
            fixture.knowledge.records.contains { draft.revisions[candidate.sourceIndex].matches($0) && $0.text.contains(candidate.quote) }
        })
        let saved = try fixture.saveDraft()
        #expect(saved.body == draft.markdownBody)
        #expect(draft.revisions.allSatisfy { saved.body.contains($0.citationTarget) && saved.body.contains($0.contentHash) })
    }

    @MainActor private final class Fixture {
        let root: URL
        let sources: URL
        let notesDirectory: URL
        let knowledge = LocalKnowledge(persistenceURL: nil)
        let vault: GeneratedKnowledgeVault
        let manager: KnowledgeVaultManager
        var grants: [ScopeGrant] { [.init(path: sources.path)] }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "relay-cross-source-" + UUID().uuidString, directoryHint: .isDirectory)
            sources = root.appending(path: "sources", directoryHint: .isDirectory)
            notesDirectory = root.appending(path: "notes", directoryHint: .isDirectory)
            vault = .init(directoryURL: root.appending(path: "cache"))
            manager = .init(directoryURL: notesDirectory)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            knowledge.onRecordsChanged = { [vault] in vault.reconcile(records: $0) }
        }
        func seed() throws {
            try write("[[Project: Marigold]]\nThe workshop starts Monday at 10:00.\nThe optional room tour follows at 11:30.", name: "a.md")
            try write("[[Project: Marigold]]\nParticipants need a laptop and charger.\nCafé 🌍 provides the workshop refreshments.", name: "b.md")
        }
        func write(_ text: String, name: String) throws { try Data(text.utf8).write(to: sources.appending(path: name), options: .atomic) }
        func index() async { await knowledge.index(grants: grants) }
        func input(_ records: [KnowledgeRecord]? = nil) throws -> CrossSourceKnowledge.Input {
            let records = records ?? knowledge.records
            let entity = try #require(CrossSourceKnowledge.entities(in: records).first)
            return try CrossSourceKnowledge.input(entityURL: entity.id, records: records)
        }
        func reply(for input: CrossSourceKnowledge.Input) -> ModelReply {
            let ids = [0, 1].compactMap { index in input.candidates.first { $0.sourceIndex == index }?.id }
            return .init(content: "{\"highlights\":[" + ids.map(String.init).joined(separator: ",") + "]}", toolCalls: [])
        }
        func consolidate(_ entity: URL, complete: @escaping ([ModelMessage]) async throws -> ModelReply) async {
            await vault.consolidate(entityURL: entity, records: knowledge.records,
                isCurrent: { [self] in knowledge.revalidate($0, grants: grants) }, complete: complete)
        }
        func changedRecords(_ kind: String) -> [KnowledgeRecord] {
            let records = knowledge.records
            if kind == "revoked" { return Array(records.dropFirst()) }
            return records.enumerated().map { index, record in
                guard index == 0 else { return record }
                return KnowledgeRecord(sourcePath: record.sourcePath, title: kind == "title" ? "Changed title" : record.title,
                    text: kind == "text" ? record.text + " additional text" : record.text,
                    modifiedAt: kind == "modified" ? record.modifiedAt.addingTimeInterval(1) : record.modifiedAt,
                    contentHash: kind == "hash" ? String(repeating: "0", count: 64) : record.contentHash,
                    byteCount: kind == "bytes" ? record.byteCount + 1 : record.byteCount,
                    coverageNote: kind == "coverage" ? "Changed coverage" : record.coverageNote)
            }
        }
        @discardableResult func saveDraft(id: UUID? = nil) throws -> LocalMarkdownNote {
            let draft = try #require(vault.consolidationDraft)
            return try vault.saveConsolidationDraft(id: id ?? draft.id, title: draft.title, body: draft.markdownBody,
                records: knowledge.records, isCurrent: { [self] in knowledge.revalidate($0, grants: grants) }) {
                    try self.manager.saveNote(title: $0, body: $1)
                }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

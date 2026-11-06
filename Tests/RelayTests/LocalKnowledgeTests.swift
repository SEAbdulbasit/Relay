import Foundation
import Testing
@testable import Relay

@MainActor
struct LocalKnowledgeTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-knowledge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ text: String, to path: URL) throws { try Data(text.utf8).write(to: path) }

    @Test func indexesOnlyExplicitSupportedVisibleSourcesAndRanksExcerpts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try write("Orchard design notes with apples and pears", to: selected.appendingPathComponent("orchard.md"))
        try write("apples are red", to: selected.appendingPathComponent("other.txt"))
        try write("secret apples", to: selected.appendingPathComponent(".hidden.txt"))
        try write("private database apples", to: selected.appendingPathComponent("database.db"))
        try write("outside apples", to: root.appendingPathComponent("outside.txt"))
        let grants = [ScopeGrant(path: selected.path)]
        let knowledge = LocalKnowledge(persistenceURL: nil)
        #expect(knowledge.records.isEmpty)
        #expect(knowledge.search(query: "apples", grants: grants).isEmpty)
        await knowledge.index(grants: grants)
        #expect(knowledge.records.count == 2)
        let results = knowledge.search(query: "orchard", grants: grants)
        #expect(results.count == 1)
        #expect(results[0].title == "orchard.md")
        #expect(results[0].excerpt.contains("Orchard"))
        #expect(results[0].sourcePath.hasSuffix("/selected/orchard.md"))
        #expect(knowledge.exportMarkdown().contains("not approved preference memory"))
    }

    @Test func indexesRecentAttributedWhatsAppMessagesFromAnExplicitExport() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let export = root.appending(path: "_chat.txt")
        let chat = """
        \u{200E}[1/11/26, 1:41:02\u{202F}PM] Messages use end-to-end encryption.
        [1/11/26, 1:42:03\u{202F}PM] Mira: Earlier message outside the recent excerpt
        [1/11/26, 1:43:04\u{202F}PM] Omar: Orchard handoff
        Meet at the north gate.
        """
        try write(chat, to: export)
        let grants = [ScopeGrant(path: root.path), ScopeGrant(path: export.path)]
        let knowledge = LocalKnowledge(persistenceURL: nil, limits: .init(maxTextBytes: 90))
        await knowledge.index(grants: grants)
        let record = try #require(knowledge.records.first)
        #expect(record.text == "[1/11/26, 1:43:04\u{202F}PM] Omar\nOrchard handoff\nMeet at the north gate.")
        #expect(record.coverageNote?.contains("Indexed 1 of 2 attributed messages") == true)
        #expect(record.coverageNote?.contains("Skipped 1 entry") == true)
        #expect(knowledge.search(query: "Orchard", grants: grants).first?.sourcePath == record.sourcePath)
        #expect(knowledge.search(query: "Earlier", grants: grants).isEmpty)

        let folderOnly = LocalKnowledge(persistenceURL: nil)
        await folderOnly.index(grants: [.init(path: root.path)])
        #expect(folderOnly.records.first?.text == chat)
        #expect(folderOnly.records.first?.coverageNote == nil)
    }

    @Test func preservesAndroidAttributionAndDeclinesUnknownTimestampSyntax() throws {
        let chat = """
        6/11/26, 13:55 - Asha: First message
        6/11/26, 14:01 - Leila: Second message
        """
        let fileName = "WhatsApp Chat with Fixture.txt"
        let result = try #require(WhatsAppExportReader.excerpt(text: chat, fileName: fileName, maximumBytes: 1_000))
        #expect(result.text == "[6/11/26, 13:55] Asha\nFirst message\n\n[6/11/26, 14:01] Leila\nSecond message")
        #expect(WhatsAppExportReader.excerpt(text: chat, fileName: "meeting.txt", maximumBytes: 1_000) == nil)
        let changedFormat = chat + "\n6/11/26, 14:05 >> Juan: Do not assign this to Leila"
        #expect(WhatsAppExportReader.excerpt(text: changedFormat, fileName: fileName, maximumBytes: 1_000) == nil)
    }

    @Test func rejectedSymlinkLeafDoesNotHideTheFollowingAllowedNestedFolder() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try write("Outside content must not appear", to: outside)
        try FileManager.default.createSymbolicLink(at: selected.appendingPathComponent("a-link.txt"), withDestinationURL: outside)
        let nested = selected.appendingPathComponent("z-allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let document = nested.appendingPathComponent("wanted.md")
        try write("Nested allowed coverage marker", to: document)
        let knowledge = LocalKnowledge(persistenceURL: nil)
        await knowledge.index(grants: [.init(path: selected.path)])
        #expect(knowledge.records.count == 1)
        #expect(knowledge.records.first?.sourcePath == (try ToolPolicy.canonicalURL(document.path).path))
        #expect(knowledge.records.first?.text == "Nested allowed coverage marker")
    }

    @Test func escapingSymlinksAndSiblingScopeAreExcluded() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try write("unique escape content", to: outside)
        try FileManager.default.createSymbolicLink(at: selected.appendingPathComponent("escape.txt"), withDestinationURL: outside)
        let knowledge = LocalKnowledge(persistenceURL: nil)
        await knowledge.index(grants: [ScopeGrant(path: selected.path)])
        #expect(knowledge.records.isEmpty)
        #expect(knowledge.search(query: "escape", grants: [ScopeGrant(path: selected.path + "/../missing")]).isEmpty)
    }

    @Test func changedDeletedAndRevokedRecordsArePurgedWithoutImplicitRefresh() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("notes.md")
        try write("old content", to: path)
        let grants = [ScopeGrant(path: root.path)]
        let knowledge = LocalKnowledge(persistenceURL: nil)
        await knowledge.index(grants: grants)
        let modified = try #require(knowledge.records.first?.modifiedAt)
        try write("new content", to: path)
        // Same byte count and mtime cannot hide a changed payload from the digest check.
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
        #expect(knowledge.search(query: "old", grants: grants).isEmpty)
        #expect(knowledge.records.isEmpty)
        #expect(knowledge.search(query: "new", grants: grants).isEmpty)
        await knowledge.index(grants: grants)
        #expect(knowledge.records.count == 1)
        try FileManager.default.removeItem(at: path)
        #expect(knowledge.search(query: "new", grants: grants).isEmpty)
        try write("restored content", to: path)
        await knowledge.index(grants: grants)
        #expect(knowledge.search(query: "restored", grants: []).isEmpty)
        #expect(knowledge.records.isEmpty)
    }

    @Test func persistenceIsLocalBoundedAndCorruptionFailsClosed() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("notes.txt")
        let state = root.appendingPathComponent("index.data")
        try write("local knowledge", to: document)
        let grants = [ScopeGrant(path: document.path)]
        let knowledge = LocalKnowledge(persistenceURL: state)
        await knowledge.index(grants: grants)
        #expect(LocalKnowledge(persistenceURL: state).records.count == 1)
        let restored = LocalKnowledge(persistenceURL: state)
        #expect(restored.search(query: "knowledge", grants: []).isEmpty)
        #expect(LocalKnowledge(persistenceURL: state).records.isEmpty)
        try write("not JSON", to: state)
        let corrupt = LocalKnowledge(persistenceURL: state)
        #expect(corrupt.records.isEmpty)
        #expect(corrupt.status.contains("could not be read safely"))
    }

    @Test func limitsBoundFileCountBytesTextAndQueries() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<8 { try write("éééééééééé", to: root.appendingPathComponent("\(i).txt")) }
        var limits = KnowledgeLimits()
        limits.maxFiles = 2; limits.maxFileBytes = 25; limits.maxTotalBytes = 40; limits.maxTextBytes = 5
        let knowledge = LocalKnowledge(persistenceURL: nil, limits: limits)
        await knowledge.index(grants: [ScopeGrant(path: root.path)])
        #expect(knowledge.records.count == 2)
        #expect(knowledge.records.allSatisfy { $0.text.utf8.count <= 5 && !$0.text.contains("�") })
        #expect(knowledge.records.reduce(0) { $0 + $1.byteCount } <= 40)
        #expect(knowledge.status.contains("limits reached"))
        #expect(knowledge.search(query: String(repeating: "a", count: 257), grants: [ScopeGrant(path: root.path)]).isEmpty)
    }

    @Test func cancelDoesNotPublishPartialIndexAndForgetDoesNotDeleteSources() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("keep.txt")
        try write("original source", to: keep)
        let knowledge = LocalKnowledge(persistenceURL: nil)
        await knowledge.index(grants: [ScopeGrant(path: keep.path)])
        for i in 0..<50 { try write("another source", to: root.appendingPathComponent("file\(i).txt")) }
        let task = Task { await knowledge.index(grants: [ScopeGrant(path: root.path)]) }
        for _ in 0..<100 where !knowledge.isIndexing { await Task.yield() }
        knowledge.cancel()
        await task.value
        #expect(knowledge.records.count == 1)
        #expect(!knowledge.isIndexing)
        knowledge.removeSource(path: keep.path)
        #expect(knowledge.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: keep.path))
        await knowledge.index(grants: [ScopeGrant(path: keep.path)])
        knowledge.clear()
        #expect(knowledge.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }
}

import Foundation
import Testing
@testable import Relay

@MainActor
struct LocalMarkdownNotesTests {
    @Test func editableMarkdownSurvivesReopeningAndKeepsPrivatePermissions() throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KnowledgeVaultManager(directoryURL: directory)
        let body = "\n- Morning café\n- [[Roadmap]]\n"
        let created = try manager.saveNote(title: "Friday notes", body: body)
        let reopened = try #require(KnowledgeVaultManager(directoryURL: directory).loadNotes().first)
        #expect(reopened.title == "Friday notes")
        #expect(reopened.body == body)
        #expect(try String(contentsOf: created.url, encoding: .utf8) == "# Friday notes\n\n" + body)
        let attributes = try FileManager.default.attributesOfItem(atPath: created.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let edited = try manager.saveNote(title: "Weekend notes", body: "Updated", replacing: reopened)
        #expect(edited.url == created.url)
        #expect(try manager.loadNotes() == [edited])
    }

    @Test func externalEditAndSymlinksCannotBeOverwritten() throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KnowledgeVaultManager(directoryURL: directory)
        let original = try manager.saveNote(title: "Original", body: "Initial")
        try "# Changed outside Relay\n\nKeep this".write(to: original.url, atomically: true, encoding: .utf8)
        #expect(throws: RelayError.self) {
            try manager.saveNote(title: "Stale draft", body: "", replacing: original)
        }
        let link = directory.appending(path: "alias.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original.url)
        let notes = try manager.loadNotes()
        #expect(notes.count == 1)
        #expect(notes.first?.body == "Keep this")
    }

    @Test func sourceExportIncludesProvenanceAndQuotesUntrustedMarkdown() throws {
        let record = KnowledgeRecord(
            sourcePath: "/fixtures/Source.md", title: "Source.md",
            text: "~~~~\n![external](https://example.com/example.png)", modifiedAt: Date(timeIntervalSince1970: 0),
            contentHash: "fixture-sha", byteCount: 51, coverageNote: "Only a limited excerpt was indexed."
        )
        let document = try #require(String(data: IndexedSourceMarkdown.data(for: record), encoding: .utf8))
        #expect(document.contains("Original source: \"/fixtures/Source.md\""))
        #expect(document.contains("SHA-256 of source: fixture-sha"))
        #expect(document.contains("Coverage: Only a limited excerpt was indexed."))
        #expect(document.contains("~~~~~text\n" + record.text + "\n~~~~~"))
    }

    private func fixtureDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "relay-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

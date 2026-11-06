import Foundation
import Testing
@testable import Relay

@MainActor
struct LocalMarkdownFoldersTests {
    @Test func foldersPersistAndPreserveExistingNoteIdentityAndEditLocation() throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KnowledgeVaultManager(directoryURL: directory)
        let rootNote = try manager.saveNote(title: "Original note", body: "Stays selected")
        let rootGraphURL = rootNote.graphURL
        let empty = try manager.createFolder(named: "Empty folder")
        let work = try manager.createFolder(named: "Work notes")
        let saved = try manager.saveNote(title: "Planning", body: "First draft", folder: work.name)
        #expect(saved.url.deletingLastPathComponent().lastPathComponent == work.name)

        let reopened = KnowledgeVaultManager(directoryURL: directory)
        let folders = try reopened.loadFolders()
        #expect(folders == [empty, work])
        let notes = try reopened.loadNotes()
        #expect(notes.first(where: { $0.title == rootNote.title })?.graphURL == rootGraphURL)
        let folderNote = try #require(notes.first { $0.title == saved.title })
        #expect(folderNote.folderName == work.name)
        let edited = try reopened.saveNote(title: "Updated planning", body: "Second draft", replacing: folderNote)
        #expect(edited.graphURL == folderNote.graphURL)
        #expect(edited.url == saved.url)
        #expect(edited.folderName == work.name)
        #expect(edited.body == "Second draft")

        let graph = SkyGraph.build(records: [], customNotes: try reopened.loadNotes().graphNotes, folders: folders)
        #expect(graph.nodes.contains(where: { $0.url == rootGraphURL }))
        let index = try #require(graph.nodes.firstIndex { $0.url == edited.graphURL })
        let folderIndex = try #require(graph.nodes.firstIndex { $0.title == work.name && $0.url.host == "group" })
        #expect(graph.adjacency[index].contains(folderIndex))
        #expect(graph.nodes.contains { $0.title == empty.name && $0.url.host == "group" })
    }

    @Test func folderIdentitySeparatesDuplicateFilenamesAndNeverRecursesOrFollowsLinks() throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KnowledgeVaultManager(directoryURL: directory)
        let first = try manager.createFolder(named: "First")
        let second = try manager.createFolder(named: "Second")
        let firstPath = directory.appending(path: first.name, directoryHint: .isDirectory)
        let secondPath = directory.appending(path: second.name, directoryHint: .isDirectory)
        try Data("# First note\n\nRoot-level within First.".utf8).write(to: firstPath.appending(path: "Note.md"))
        try Data("# Second note\n\nRoot-level within Second.".utf8).write(to: secondPath.appending(path: "Note.md"))

        let nested = firstPath.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("# Nested note\n\nMust not be read.".utf8).write(to: nested.appending(path: "Secret.md"))
        let link = directory.appending(path: "Linked folder", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nested)

        let notes = try manager.loadNotes()
        #expect(notes.map(\.title) == ["First note", "Second note"])
        #expect(Set(notes.map(\.graphURL)).count == 2)
        #expect(try manager.loadFolders() == [first, second])
        #expect(throws: RelayError.self) {
            try manager.saveNote(title: "Do not follow", body: "", folder: "Linked folder")
        }
        #expect(throws: RelayError.self) { try manager.createFolder(named: "../Escape") }
        #expect(throws: RelayError.self) { try manager.createFolder(named: first.name) }
    }

    private func fixtureDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "relay-note-folders-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

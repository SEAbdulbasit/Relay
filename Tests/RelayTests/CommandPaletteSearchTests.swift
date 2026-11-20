import Foundation
import Testing
@testable import Relay

struct CommandPaletteSearchTests {
    @Test func searchesMessageBodiesAndNotesLocallyInArchiveOrder() async throws {
        let first = SavedConversationThread(title: "Café plans", messages: [.init(role: "user", text: "Lunch")])
        let second = SavedConversationThread(title: "Other", messages: [.init(role: "assistant", text: "A cafe meeting")])
        let noteURL = URL(fileURLWithPath: "/synthetic/meeting.md")
        let result = try await CommandPaletteSearch.search(threads: [first, second],
            notes: [.init(id: noteURL, title: "Meeting", body: "CAFE")], query: "cafe")
        #expect(result.threads == [first.id, second.id])
        #expect(result.notes == [noteURL])
    }

    @Test func resultLimitsPreserveTheFirstMatchesAndEmptyQueryOrder() async throws {
        let threads = (0..<60).map { _ in SavedConversationThread(messages: [.init(role: "user", text: "match")]) }
        let notes = (0..<100).map { CommandPaletteSearch.Note(id: URL(fileURLWithPath: "/synthetic/\($0).md"), title: "match", body: "") }
        for query in ["match", "  "] {
            let result = try await CommandPaletteSearch.search(threads: threads, notes: notes, query: query)
            #expect(result.threads == Array(threads.prefix(8).map(\.id)))
            #expect(result.notes == Array(notes.prefix(6).map(\.id)))
        }
    }

    @Test func cancelledSearchCannotReturnStaleResults() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CommandPaletteSearch.search(threads: [], notes: [], query: "match")
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled searches must not publish results")
        } catch {
            #expect(error is CancellationError)
        }
    }
}

@MainActor
struct KnowledgeNoteDestinationTests {
    @Test func exactFolderNoteResolvesAfterReloadAndSameNoteCanBeRequestedAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-navigation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KnowledgeVaultManager(directoryURL: directory)
        let folder = try manager.createFolder(named: "Project Café")
        let first = try manager.saveNote(title: "Meeting", body: "Root note")
        let second = try manager.saveNote(title: "Meeting", body: "Project note", folder: folder.name)
        let destination = KnowledgeNoteDestination(note: second)
        let reloaded = try manager.loadNotes()
        #expect(destination.resolve(in: reloaded)?.url == second.url)
        #expect(destination.resolve(in: [first]) == nil)
        #expect(KnowledgeNoteDestination(note: second) != destination)
    }

    @Test func removedNoteDoesNotResolveToAnotherNote() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-navigation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KnowledgeVaultManager(directoryURL: directory)
        let original = try manager.saveNote(title: "Original", body: "")
        let request = KnowledgeNoteDestination(note: original)
        try FileManager.default.removeItem(at: original.url)
        _ = try manager.saveNote(title: "Different", body: "")
        #expect(request.resolve(in: try manager.loadNotes()) == nil)
    }
}

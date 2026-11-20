import Foundation

/// A new request identity allows opening the same result again after navigation.
struct KnowledgeNoteDestination: Equatable, Identifiable {
    let id = UUID()
    let graphURL: URL

    init(note: LocalMarkdownNote) { graphURL = note.graphURL }

    func resolve(in currentNotes: [LocalMarkdownNote]) -> LocalMarkdownNote? {
        currentNotes.first { $0.graphURL == graphURL }
    }
}

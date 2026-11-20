import Foundation

/// The palette searches private snapshots locally. Matching never needs the UI actor.
nonisolated enum CommandPaletteSearch {
    struct Note: Sendable {
        let id: URL
        let title: String
        let body: String
    }

    struct Result: Sendable {
        let threads: [UUID]
        let notes: [URL]
    }

    @concurrent
    static func search(threads: [SavedConversationThread], notes: [Note], query: String) async throws -> Result {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var threadIDs: [UUID] = []
        for thread in threads {
            try Task.checkCancellation()
            var matches = term.isEmpty || thread.title.localizedStandardContains(term) || thread.preview.localizedStandardContains(term)
            if !matches {
                for message in thread.messages {
                    try Task.checkCancellation()
                    if message.text.localizedStandardContains(term) { matches = true; break }
                }
            }
            if matches { threadIDs.append(thread.id) }
            if threadIDs.count == 8 { break }
        }
        var noteIDs: [URL] = []
        for note in notes {
            try Task.checkCancellation()
            if term.isEmpty || note.title.localizedStandardContains(term) || note.body.localizedStandardContains(term) {
                noteIDs.append(note.id)
            }
            if noteIDs.count == 6 { break }
        }
        try Task.checkCancellation()
        return Result(threads: threadIDs, notes: noteIDs)
    }
}

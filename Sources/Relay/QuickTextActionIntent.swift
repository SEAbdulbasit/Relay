import Foundation

/// Recognizes an explicit request, never its source or authorization. Callers
/// must independently bind the selected text/current document before capture.
nonisolated struct QuickTextActionIntent: Equatable, Sendable {
    enum Action: String, Sendable { case summarize, proofread }
    enum Target: String, Sendable { case current, selection, page, document, conversation }
    let action: Action
    let target: Target

    static func parse(_ text: String) -> Self? {
        guard !text.isEmpty, text.utf8.count <= 1_000,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !text.contains(where: \.isNewline),
              !text.contains(where: { "\"“”„«»`".contains($0) }) else { return nil }
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "’", with: "'")
        while let last = normalized.last, ".!?".contains(last) { normalized.removeLast() }
        // Commas separate polite/address phrases; all remaining words still have
        // to match the complete grammar, so comma-separated compound work fails.
        var words = normalized.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        if words.starts(with: ["hey", "relay"]) { words.removeFirst(2) }
        else if words.first == "relay" { words.removeFirst() }
        if words.count >= 2, ["can", "could", "would", "will"].contains(words[0]), words[1] == "you" {
            words.removeFirst(2)
        }
        if words.first == "please" { words.removeFirst() }
        let action: Action
        if words.first == "summarize" || words.first == "summarise" {
            action = .summarize
            words.removeFirst()
        } else if words.first == "proofread" {
            action = .proofread
            words.removeFirst()
        } else if words.starts(with: ["proof", "read"]) {
            action = .proofread
            words.removeFirst(2)
        } else { return nil }
        if words.last == "please" { words.removeLast() }
        if words.suffix(2).elementsEqual(["for", "me"]) { words.removeLast(2) }
        let targetText = words.joined(separator: " ")
        if selectionTargets.contains(targetText) { return Self(action: action, target: .selection) }
        if currentTargets.contains(targetText) {
            return Self(action: action, target: action == .proofread ? .selection : .current)
        }
        // Proofreading is a selected-text workflow. An explicit page/document
        // request remains ordinary conversation rather than widening its edit.
        guard action == .summarize else { return nil }
        if conversationTargets.contains(targetText) { return Self(action: action, target: .conversation) }
        if pageTargets.contains(targetText) { return Self(action: action, target: .page) }
        if documentTargets.contains(targetText) { return Self(action: action, target: .document) }
        return nil
    }

    private static let currentTargets: Set<String> = [
        "this", "that", "it", "this source", "the current source", "my current source"
    ]
    private static let selectionTargets: Set<String> = [
        "this text", "the current text", "my current text", "this selected text", "the selected text", "my selected text",
        "this highlighted text", "the highlighted text", "my highlighted text", "the current selected text",
        "this selection", "the selection", "my selection", "the current selection", "my current selection",
        "what i selected", "what i have selected", "what i highlighted"
    ]
    private static let pageTargets: Set<String> = [
        "this page", "that page", "this browser page", "the current page", "my current page", "the current browser page",
        "the page i'm on", "the page i am on"
    ]
    private static let documentTargets: Set<String> = [
        "this document", "that document", "the current document", "my current document",
        "this pdf", "the current pdf", "my current pdf"
    ]
    private static let conversationTargets: Set<String> = [
        "this chat", "that chat", "the current chat", "my current chat",
        "this conversation", "that conversation", "the current conversation", "my current conversation"
    ]
}

import Foundation

/// Bounded, gesture-initiated retrieval over the existing selected-source index.
/// Search ranks candidates; a document title or explicit entity link must also
/// anchor each passage to the visible reply context before it reaches inference.
@MainActor
enum FocusedDraftKnowledge {
    static let maximumPassages = 3
    static let maximumPassageBytes = 800
    static let maximumPayloadBytes = 6_000

    nonisolated struct Passage: Codable, Equatable, Sendable {
        let citation: String
        let source: CrossSourceKnowledge.Revision
        let anchor: String
        let quote: String

        var modelPassage: ModelPassage {
            .init(citation: citation, source_title: source.title, coverage: source.coverage,
                  quote: quote, revision_digest: String(source.citationTarget.dropFirst("Source: ".count)))
        }
    }

    /// Paths, file hashes, timestamps and local revalidation receipts stay in
    /// Passage.source. Automatic drafting gets only these bounded source fields.
    nonisolated struct ModelPassage: Encodable, Sendable {
        let citation: String
        let source_title: String
        let coverage: String
        let quote: String
        let revision_digest: String
    }

    struct Snapshot {
        let passages: [Passage]
        private let checkCurrent: @MainActor () -> Bool
        static var empty: Self { .init(passages: [], checkCurrent: { true }) }

        init(passages: [Passage], checkCurrent: @escaping @MainActor () -> Bool) {
            self.passages = passages
            self.checkCurrent = checkCurrent
        }

        func validate() throws {
            try Task.checkCancellation()
            guard checkCurrent() else {
                throw RelayError.message("The retrieved knowledge changed or access was removed. The reply field was left alone.")
            }
        }
    }

    static func query(editorText: String, thread: [String]) -> String {
        // The current reply and newest incoming excerpt get the limited query
        // budget before older conversation, rather than being crowded out by it.
        let context = ([editorText] + thread.suffix(8).reversed()).joined(separator: " ")
        var seen = Set<String>(), selected: [String] = []
        for word in words(context) where word.count >= 3 && !stopWords.contains(word) {
            guard seen.insert(word).inserted else { continue }
            let next = (selected + [word]).joined(separator: " ")
            guard next.utf8.count <= 256 else { break }
            selected.append(word)
            if selected.count == 16 { break }
        }
        return selected.joined(separator: " ")
    }

    static func retrieve(query: String, knowledge: LocalKnowledge, search: KnowledgeSearchCoordinator,
                         currentGrants: @escaping @MainActor () -> [ScopeGrant]) async throws -> Snapshot {
        try Task.checkCancellation()
        guard !query.isEmpty, query.utf8.count <= 256, !search.isBusy else { return .empty }
        let scope = currentGrants()
        let initial = knowledge.records
        let results = try await search.search(query: query, constrainedTo: scope)
        try Task.checkCancellation()
        var passages: [Passage] = [], bound: [KnowledgeRecord] = []
        for result in results {
            guard let original = initial.first(where: { Data($0.sourcePath.utf8) == Data(result.sourcePath.utf8) }),
                  let record = knowledge.records.first(where: { Data($0.sourcePath.utf8) == Data(result.sourcePath.utf8) }) else { continue }
            guard CrossSourceKnowledge.Revision(original).matches(record), knowledge.revalidate(record, grants: currentGrants()) else {
                throw RelayError.message("The retrieved source changed while searching. The reply field was left alone.")
            }
            guard record.sourcePath.utf8.count <= 1_024, record.title.utf8.count <= 256,
                  (record.coverageNote?.utf8.count ?? 0) <= 4_096,
                  !containsProtectedData(record.title),
                  !containsProtectedData(record.coverageNote ?? ""),
                  let anchor = anchor(in: record, query: query),
                  !containsProtectedData(anchor),
                  let quote = relevantQuote(in: record, query: query), !containsProtectedData(quote) else { continue }
            let passage = Passage(citation: "K\(passages.count + 1)", source: .init(record), anchor: anchor, quote: quote)
            let data = try JSONEncoder().encode((passages + [passage]).map(\.modelPassage))
            guard data.count <= maximumPayloadBytes else { continue }
            passages.append(passage)
            bound.append(record)
            if passages.count == maximumPassages { break }
        }
        let records = bound
        let snapshot = Snapshot(passages: passages) {
            records.allSatisfy { record in
                guard let current = knowledge.records.first(where: { Data($0.sourcePath.utf8) == Data(record.sourcePath.utf8) }),
                      CrossSourceKnowledge.Revision(record).matches(current),
                      (try? ToolPolicy.scopedURL(record.sourcePath, grants: scope))?.path == record.sourcePath else { return false }
                return knowledge.revalidate(record, grants: currentGrants())
            }
        }
        try snapshot.validate()
        return snapshot
    }

    private static func anchor(in record: KnowledgeRecord, query: String) -> String? {
        let queryWords = Set(words(query))
        for line in KnowledgeWikiLink.lines(in: GeneratedKnowledgeVault.boundedUTF8(record.text, limit: 32_768)) where line.allowsLinks {
            for link in KnowledgeWikiLink.inLine(line.text) {
                guard let entity = link.relationship else { continue }
                let tokens = Set(words(entity.name).filter { !stopWords.contains($0) })
                if tokens.contains(where: { $0.count >= 3 && !genericTitles.contains($0) }), tokens.isSubset(of: queryWords) {
                    return "Explicit \(entity.kind.rawValue) link: \(entity.name)"
                }
            }
        }
        let title = URL(fileURLWithPath: record.title).deletingPathExtension().lastPathComponent
        let tokens = Set(words(title).filter { $0.count >= 3 && !stopWords.contains($0) && !genericTitles.contains($0) })
        guard !tokens.isEmpty, tokens.isSubset(of: queryWords) else { return nil }
        return "Document title: " + record.title
    }

    private static func relevantQuote(in record: KnowledgeRecord, query: String) -> String? {
        let terms = Set(words(query))
        let paragraphs = plainParagraphs(in: record.text)
        let candidates = paragraphs.compactMap { paragraph -> (text: String, score: Int)? in
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            let lines = text.split(whereSeparator: \.isNewline)
            if lines.allSatisfy({ $0.hasPrefix("#") }) { return nil }
            let links = KnowledgeWikiLink.inLine(text)
            if links.count == 1, links[0].range == text.startIndex..<text.endIndex { return nil }
            // Keep a contiguous source substring. No inferred facts, stitched
            // sentences, coverage text, or model-written excerpts enter this quote.
            let quote = GeneratedKnowledgeVault.boundedUTF8(text, limit: maximumPassageBytes)
            let score = Set(words(quote)).intersection(terms).count
            guard score > 0 else { return nil }
            return (quote, score)
        }
        return candidates.enumerated().max { left, right in
            left.element.score == right.element.score ? left.offset > right.offset : left.element.score < right.element.score
        }?.element.text
    }

    /// Keep original substring ranges (including literal CRLF/Unicode bytes),
    /// while excluding fenced code and separating paragraphs at blank lines.
    private static func plainParagraphs(in text: String) -> [String] {
        var result: [String] = [], start: String.Index?, end: String.Index?
        func flush() {
            if let start, let end { result.append(String(text[start..<end])) }
            start = nil; end = nil
        }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (line, metadata) in zip(lines, KnowledgeWikiLink.lines(in: text)) {
            guard metadata.allowsLinks, !line.trimmingCharacters(in: .whitespaces).isEmpty else { flush(); continue }
            if start == nil { start = line.startIndex }
            end = line.endIndex
        }
        flush()
        return result
    }

    private static func containsProtectedData(_ text: String) -> Bool {
        if PIIScan.containsHighRiskPII(text) { return true }
        let lower = text.lowercased()
        return ["password", "passwd", "api_key", "api key", "access token", "refresh token", "secret key",
                "private key", "recovery phrase", "bearer ", "credentials", "-----begin"]
            .contains(where: lower.contains) || keyPattern?.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    // Provider key prefixes must begin a token and carry actual key material;
    // an ordinary task-notes or desk-notes title is not an API credential.
    private static let keyPattern = try? NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9_])(?:sk-(?:proj-|svcacct-)?[a-z0-9_-]{16,}|ghp_[a-z0-9]{20,}|github_pat_[a-z0-9_]{20,})(?![a-z0-9_])"#)

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    private static let stopWords: Set<String> = ["the", "and", "for", "with", "from", "about", "this", "that", "these", "those", "what", "when", "where", "which", "how", "can", "could", "would", "should", "does", "did", "please", "thanks", "thank", "hello", "you", "your", "our", "their", "they", "have", "has", "had", "are", "was", "were", "will", "been", "not", "send", "tell", "reply", "date", "time", "status"]
    private static let genericTitles: Set<String> = ["notes", "note", "plan", "plans", "project", "projects", "meeting", "meetings", "schedule", "launch", "release", "workshop", "document", "summary", "report", "todo", "task", "archive", "budget", "roadmap", "brief", "details", "calendar", "update"]
}

/// Synthetic editor tests exercise the same retrieval/model/commit sequence as
/// the native controller without creating an Accessibility or keyboard monitor.
@MainActor
struct FocusedDraftCapture {
    let name: String
    let original: String
    let thread: [String]
    let processID: Int32?
    let validate: () throws -> Void
    let insert: (String, TimeInterval, () throws -> Void) throws -> Void
}

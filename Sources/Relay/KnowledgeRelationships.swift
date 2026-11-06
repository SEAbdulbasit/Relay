import Foundation

struct KnowledgeRelationship {
    enum Kind: String, CaseIterable {
        case person, project

        var title: String { self == .person ? "Person" : "Project" }
        var domain: String { self == .person ? "People" : "Projects" }
        var icon: String { self == .person ? "person.2" : "briefcase" }

        static func from(_ url: URL) -> Self? {
            guard url.scheme == "relay-vault", let host = url.host else { return nil }
            return Self(rawValue: host)
        }
    }

    let kind: Kind
    let name: String

    init?(kind: Kind, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !clean.isEmpty, clean.utf8.count <= 120,
              !clean.contains(where: \.isNewline),
              !clean.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !clean.contains(where: { "[]|`".contains($0) }) else { return nil }
        self.kind = kind
        self.name = clean
    }

    init?(target: String) {
        let parts = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = Kind(rawValue: parts[0].trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
        self.init(kind: kind, name: String(parts[1]))
    }

    var url: URL {
        let normalized = name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        return URL(string: "relay-vault://\(kind.rawValue)")!
            .appending(queryItems: [URLQueryItem(name: "name", value: normalized)])
    }

    var markdown: String { "[[\(kind.title): \(name)]]" }
}

struct KnowledgeWikiLink {
    let range: Range<String.Index>
    let target: String
    let label: String
    let relationship: KnowledgeRelationship?

    // Match code spans as complete tokens so link syntax inside them stays literal.
    private static let pattern = try! NSRegularExpression(pattern: #"(?<!\\)\[\[([^\]\r\n]+)\]\]|(?<!`)(`+)(?!`)[^\r\n]*?(?<!`)\2(?!`)"#)

    static func inLine(_ line: String) -> [Self] {
        guard line.contains("[[") else { return [] }
        return pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let contents = Range(match.range(at: 1), in: line), let whole = Range(match.range, in: line) else { return nil }
            let parts = line[contents].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = parts[0].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            let relationship = KnowledgeRelationship(target: target)
            let alias = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return Self(range: whole, target: target, label: alias.isEmpty ? relationship?.name ?? target : alias,
                        relationship: relationship)
        }
    }

    static func lines(in body: String) -> [(text: String, allowsLinks: Bool)] {
        var fence: (marker: Character, length: Int)?
        return body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            let trimmed = line.drop(while: \.isWhitespace)
            if let current = fence {
                let close = trimmed.prefix(while: { $0 == current.marker })
                if close.count >= current.length, trimmed.dropFirst(close.count).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                return (String(line), false)
            }
            if let marker = trimmed.first, marker == "~" || marker == "`" {
                let length = trimmed.prefix(while: { $0 == marker }).count
                if length >= 3 {
                    fence = (marker, length)
                    return (String(line), false)
                }
            }
            return (String(line), true)
        }
    }
}

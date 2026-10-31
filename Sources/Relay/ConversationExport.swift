import Foundation

/// A user-requested visible-history snapshot. Deliberately cannot accept model configuration,
/// source grants, approved memories or hidden inference messages.
nonisolated enum ConversationExport {
    enum Format: String, CaseIterable { case markdown, json }
    static let maximumInputBytes = 8 * 1_024 * 1_024
    static let maximumOutputBytes = 12 * 1_024 * 1_024
    struct Snapshot: Codable, Sendable {
        let version: Int
        let exportedAt: Date
        let messages: [ChatMessage]
        let activity: [ActivityEntry]?
    }

    static func data(messages: [ChatMessage], activity: [ActivityEntry], includeActivity: Bool,
                     format: Format, now: Date = Date()) throws -> Data {
        let selectedActivity = includeActivity ? activity : []
        guard messages.count <= 10_000, selectedActivity.count <= 20_000,
              validDate(now), messages.allSatisfy({ validDate($0.date) && $0.artifacts.count <= 100 }),
              selectedActivity.allSatisfy({ validDate($0.date) }) else {
            throw RelayError.message("This history exceeds the export limits or contains an invalid date. Nothing was exported.")
        }
        var bytes = 0
        for message in messages {
            for value in [message.role, message.text] + message.artifacts {
                guard value.utf8.count <= maximumInputBytes - bytes else { throw tooLarge() }
                bytes += value.utf8.count
            }
        }
        for entry in selectedActivity {
            for value in [entry.name, entry.detail, entry.status] {
                guard value.utf8.count <= maximumInputBytes - bytes else { throw tooLarge() }
                bytes += value.utf8.count
            }
        }
        let snapshot = Snapshot(version: 1, exportedAt: now, messages: messages,
                                activity: includeActivity ? activity : nil)
        let result: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            result = try encoder.encode(snapshot)
        case .markdown:
            let date = ISO8601DateFormatter()
            var sections = ["# Relay conversation", "Exported \(date.string(from: now)). Clear-text visible history; may contain private content and local paths. Action evidence records observations, not universal task completion."]
            if messages.isEmpty { sections.append("No visible messages.") }
            for message in messages {
                sections.append("## Message · \(date.string(from: message.date))\n\n" + fenced("Role: " + message.role) + "\n\n" + fenced(message.text))
                if !message.artifacts.isEmpty { sections.append("Artifact references (files are not copied):\n\n" + fenced(message.artifacts.joined(separator: "\n"))) }
            }
            if includeActivity {
                sections.append("## Activity snapshot\n\nOnly explicitly included activity is below. No app or file operation is performed by this export.")
                for entry in activity { sections.append(fenced("\(date.string(from: entry.date)) · \(entry.name) · \(entry.status)\n\(entry.detail)")) }
            }
            result = Data((sections.joined(separator: "\n\n") + "\n").utf8)
        }
        guard result.count <= maximumOutputBytes else { throw tooLarge() }
        return result
    }

    private static func fenced(_ text: String) -> String {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" { current += 1; longest = max(longest, current) }
            else { current = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "text\n" + text + "\n" + fence
    }
    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
    }
    private static func tooLarge() -> RelayError {
        .message("This conversation is too large for a complete export (8 MB of source text / 12 MB output limit). Nothing was truncated or exported.")
    }
}

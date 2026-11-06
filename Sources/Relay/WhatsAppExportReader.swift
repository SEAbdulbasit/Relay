import Foundation

nonisolated enum WhatsAppExportReader {
    struct Excerpt {
        let text: String
        let coverage: String
    }

    struct Parsed {
        let entries: [ChatArchiveEntry]
        let attributedCount: Int
        let unattributedCount: Int
        let bodyLimited: Bool
    }

    private static let maximumBodyCharacters = 2_000
    private static let date = #"\p{Nd}{1,4}[/.-]\p{Nd}{1,2}[/.-]\p{Nd}{1,4}\.?"#
    private static let time = #"\p{Nd}{1,2}:\p{Nd}{2}(?::\p{Nd}{2})?(?:\h*[AaPp]\.?[Mm]\.?)?"#
    private static let timestamp = date + #",?\h+"# + time
    private static let iOS = try! NSRegularExpression(pattern: "^\\[(\(timestamp))\\]\\h+(.*)$")
    private static let android = try! NSRegularExpression(pattern: "^(\(timestamp))\\h+[-–]\\h+(.*)$")
    private static let dateLikePrefix = try! NSRegularExpression(pattern: #"^\[?\p{Nd}{1,4}[/.-]\p{Nd}{1,2}[/.-]\p{Nd}{1,4}.*\p{Nd}:\p{Nd}{2}"#)

    static func parse(_ text: String, requiresRecognizedHeaders: Bool = false) throws -> Parsed? {
        var entries: [ChatArchiveEntry] = []
        var current: ChatArchiveEntry?
        var attributed = 0
        var unattributed = 0
        var bodyLimited = false
        func finishCurrent() {
            guard let current, !current.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            attributed += 1
            entries.append(current)
            if entries.count > ChatArchiveReader.maximumEntries { entries.removeFirst() }
        }
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let line = String(raw.drop(while: { "\u{feff}\u{200e}\u{200f}\u{061c}".contains($0) }))
            let range = NSRange(line.startIndex..., in: line)
            let pattern = line.hasPrefix("[") ? iOS : android
            if let header = pattern.firstMatch(in: line, range: range),
               let dateRange = Range(header.range(at: 1), in: line),
               let bodyRange = Range(header.range(at: 2), in: line) {
                finishCurrent()
                current = nil
                let content = line[bodyRange]
                guard let delimiter = content.range(of: ": ") else { unattributed += 1; continue }
                let sender = content[..<delimiter.lowerBound].trimmingCharacters(in: .whitespaces)
                guard !sender.isEmpty, sender.count <= 100,
                      !sender.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    unattributed += 1
                    continue
                }
                let message = content[delimiter.upperBound...]
                let bounded = message.prefix(maximumBodyCharacters)
                if bounded.endIndex != message.endIndex { bodyLimited = true }
                current = ChatArchiveEntry(time: String(line[dateRange]), sender: sender, body: String(bounded))
            } else if requiresRecognizedHeaders, dateLikePrefix.firstMatch(in: line, range: range) != nil {
                // Unknown timestamp syntax may start a new message. Keep the ordinary
                // text excerpt instead of assigning it to the preceding sender.
                return nil
            } else if let active = current {
                let remaining = maximumBodyCharacters - active.body.count
                guard remaining > 0 else { bodyLimited = true; continue }
                let continuation = raw.prefix(remaining - 1)
                if continuation.endIndex != raw.endIndex { bodyLimited = true }
                current = ChatArchiveEntry(time: active.time, sender: active.sender, body: active.body + "\n" + continuation)
            }
        }
        finishCurrent()
        guard !entries.isEmpty else { return nil }
        return Parsed(entries: entries, attributedCount: attributed, unattributedCount: unattributed, bodyLimited: bodyLimited)
    }

    static func excerpt(text: String, fileName: String, maximumBytes: Int) -> Excerpt? {
        let name = fileName.lowercased()
        guard maximumBytes > 0, !text.contains("\0"),
              name == "_chat.txt" || name.hasPrefix("whatsapp chat with ") && name.hasSuffix(".txt"),
              let parsed = try? parse(text, requiresRecognizedHeaders: true) else { return nil }

        var selected: [String] = []
        var remaining = maximumBytes
        var trimmedMessage = false
        for entry in parsed.entries.reversed() {
            let message = "[\(entry.time)] \(entry.sender)\n" + entry.body.trimmingCharacters(in: .newlines)
            let size = message.utf8.count + (selected.isEmpty ? 0 : 2)
            guard size <= remaining else {
                if selected.isEmpty {
                    selected.append(NativePersonalSources.bounded(message, maximumBytes: remaining))
                    trimmedMessage = true
                }
                break
            }
            selected.append(message)
            remaining -= size
        }
        let unattributed = parsed.unattributedCount
        let coverage = "WhatsApp text export. Indexed \(selected.count) of \(parsed.attributedCount) attributed messages, starting with the latest available. Sender names and times come from the file. Media stays outside the index."
            + (unattributed > 0 ? " Skipped \(unattributed) \(unattributed == 1 ? "entry" : "entries") without a readable sender." : "")
            + (parsed.bodyLimited ? " Long message bodies are limited to \(maximumBodyCharacters) characters." : "")
            + (trimmedMessage ? " The latest message exceeded the text limit." : "")
        return Excerpt(text: selected.reversed().joined(separator: "\n\n"), coverage: coverage)
    }
}

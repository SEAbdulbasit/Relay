import Foundation
import SQLite3
import Darwin

nonisolated struct ChatArchiveConversation: Identifiable, Equatable, Sendable {
    let id: Int64
    let label: String
}

nonisolated struct ChatArchiveEntry: Equatable, Sendable {
    let time: String
    let sender: String
    let body: String
}

nonisolated enum ChatArchiveReader {
    static let maximumEntries = 80
    private static let maximumExportBytes = 12 * 1_024 * 1_024

    struct FileVersion: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let bytes: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    static func version(of url: URL) throws -> FileVersion {
        var item = stat()
        guard url.isFileURL, url.host == nil || url.host == "", url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/"), !url.path.contains("\0"),
              url.path.withCString({ lstat($0, &item) }) == 0,
              item.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), item.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw RelayError.message("Choose an ordinary archive that is fully stored on this Mac.")
        }
        return FileVersion(device: item.st_dev, inode: item.st_ino, bytes: item.st_size,
                           modifiedSeconds: item.st_mtimespec.tv_sec, modifiedNanoseconds: item.st_mtimespec.tv_nsec,
                           changedSeconds: item.st_ctimespec.tv_sec, changedNanoseconds: item.st_ctimespec.tv_nsec)
    }

    @concurrent static func whatsApp(_ url: URL) async throws -> [ChatArchiveEntry] {
        try Task.checkCancellation()
        let data = try LocalStateFile.read(url, maximumBytes: maximumExportBytes)
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw RelayError.message("Choose a UTF-8 WhatsApp text export without media.")
        }
        return try parseWhatsApp(text)
    }

    static func parseWhatsApp(_ text: String) throws -> [ChatArchiveEntry] {
        let timestamp = #"[0-9]{1,4}[/.-][0-9]{1,2}[/.-][0-9]{1,4},?\s+[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?:[\s\u00A0\u202F]+(?:AM|PM))?"#
        let formats = [
            try NSRegularExpression(pattern: #"^\[("# + timestamp + #")\]\s+(.+)$"#, options: .caseInsensitive),
            try NSRegularExpression(pattern: #"^("# + timestamp + #")\s+[-–]\s+(.+)$"#, options: .caseInsensitive)
        ]
        var recent: [ChatArchiveEntry] = []
        var entry: ChatArchiveEntry?
        func finish() {
            if let entry, !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recent.append(entry)
                if recent.count > maximumEntries { recent.removeFirst() }
            }
        }
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            // Ignore presentation direction marks at the start of WhatsApp lines.
            let line = String(raw.drop(while: { $0 == "\u{200e}" || $0 == "\u{200f}" || $0 == "\u{feff}" }))
            let range = NSRange(line.startIndex..., in: line)
            if let match = formats.compactMap({ $0.firstMatch(in: line, range: range) }).first,
               let date = Range(match.range(at: 1), in: line),
               let payload = Range(match.range(at: 2), in: line) {
                finish()
                entry = nil
                let content = line[payload]
                // No sender field means a system notice; it cannot become a message continuation.
                if let separator = content.range(of: ": "), separator.lowerBound > content.startIndex,
                   content.distance(from: content.startIndex, to: separator.lowerBound) <= 100 {
                    entry = ChatArchiveEntry(time: String(line[date]), sender: String(content[..<separator.lowerBound]),
                                             body: String(content[separator.upperBound...].prefix(2_000)))
                }
            } else if let active = entry, active.body.count < 2_000 {
                entry = ChatArchiveEntry(time: active.time, sender: active.sender,
                                         body: String((active.body + "\n" + line).prefix(2_000)))
            }
        }
        finish()
        guard !recent.isEmpty else { throw RelayError.message("No supported WhatsApp message lines were found in this export.") }
        return recent
    }

    @concurrent static func messagesConversations(_ url: URL) async throws -> [ChatArchiveConversation] {
        try withDatabase(url) { db in
            try query(db, sql: """
                SELECT rowid, substr(COALESCE(NULLIF(display_name,''), chat_identifier), 1, 180)
                FROM chat ORDER BY rowid DESC LIMIT 200
                """) { row in
                    ChatArchiveConversation(id: sqlite3_column_int64(row, 0), label: text(row, 1) ?? "Conversation")
                }
        }
    }

    @concurrent static func messages(_ url: URL, chatID: Int64, days: Int, now: Date = Date()) async throws -> [ChatArchiveEntry] {
        guard chatID > 0, (1...365).contains(days) else { throw RelayError.message("Choose a conversation and a time range of 1 to 365 days.") }
        let appleEpoch: TimeInterval = 978_307_200
        let current = now.timeIntervalSince1970 - appleEpoch
        guard current.isFinite, (-1_000_000_000...20_000_000_000).contains(current) else {
            throw RelayError.message("The date range for this Messages snapshot is invalid.")
        }
        let upper = Int64(current)
        let cutoff = upper - Int64(days * 86_400)
        return try withDatabase(url) { db in
            let rows: [ChatArchiveEntry] = try query(db, sql: """
                SELECT CASE WHEN abs(m.date) > 100000000000 THEN m.date / 1000000000 ELSE m.date END,
                       m.is_from_me, substr(h.id, 1, 180), substr(m.text, 1, 2000)
                  FROM chat_message_join j
                  JOIN message m ON m.rowid = j.message_id
                  LEFT JOIN handle h ON h.rowid = m.handle_id
                 WHERE j.chat_id = ?1 AND m.text IS NOT NULL AND length(m.text) > 0
                   AND (CASE WHEN abs(m.date) > 100000000000 THEN m.date / 1000000000 ELSE m.date END) BETWEEN ?2 AND ?3
                 ORDER BY 1 DESC, m.rowid DESC LIMIT 80
                """, bind: { row in
                    sqlite3_bind_int64(row, 1, chatID) == SQLITE_OK && sqlite3_bind_int64(row, 2, cutoff) == SQLITE_OK
                        && sqlite3_bind_int64(row, 3, upper) == SQLITE_OK
                }) { row in
                    let time = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(row, 0)) + appleEpoch)
                    return ChatArchiveEntry(time: time.ISO8601Format(),
                        sender: sqlite3_column_int(row, 1) != 0 ? "Me" : text(row, 2) ?? "Participant",
                        body: text(row, 3) ?? "")
                }
            guard !rows.isEmpty else {
                throw RelayError.message("No plain-text messages were available in this conversation and time range. Rich-only messages and attachments are not included.")
            }
            return Array(rows.reversed())
        }
    }

    private static func withDatabase<T>(_ url: URL, read: (OpaquePointer) throws -> T) throws -> T {
        try Task.checkCancellation()
        let before = try version(of: url)
        guard url.isFileURL, url.query == nil, url.fragment == nil, url.host == nil || url.host == "",
              ["db", "sqlite", "sqlite3"].contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, (1...2_000_000_000).contains(bytes) else {
            throw RelayError.message("Choose a regular local Messages database snapshot up to 2 GB.")
        }
        let path = url.path
        guard !["-wal", "-journal"].contains(where: { FileManager.default.fileExists(atPath: path + $0) }) else {
            throw RelayError.message("This database has a live journal. Choose a standalone backup of Messages instead.")
        }
        var handle: OpaquePointer?
        // macOS exposes /tmp and /var through symbolic directory aliases. Resolve
        // parent aliases only after checking the selected leaf and compare its stamp.
        guard let resolved = path.withCString({ realpath($0, nil) }) else {
            throw RelayError.message("The selected archive path could not be resolved.")
        }
        defer { free(resolved) }
        let canonical = URL(fileURLWithPath: String(cString: resolved))
        guard try version(of: canonical) == before else { throw RelayError.message("The selected archive identity changed.") }
        let uri = canonical.absoluteString + "?mode=ro&immutable=1"
        let result = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard result == SQLITE_OK, let handle, sqlite3_db_readonly(handle, "main") == 1,
              sqlite3_exec(handle, "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;", nil, nil, nil) == SQLITE_OK else {
            throw RelayError.message("Messages snapshot could not be opened in read-only mode (SQLite \(result)).")
        }
        sqlite3_progress_handler(handle, 2_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        let tables = try query(handle, sql: "SELECT substr(name, 1, 128), substr(sql, 1, 64) FROM sqlite_master WHERE type = 'table' LIMIT 1000") { statement in
            (text(statement, 0) ?? "", text(statement, 1) ?? "")
        }
        let ordinary = Set(tables.filter { $0.1.uppercased().hasPrefix("CREATE TABLE") }.map(\.0))
        guard ordinary.isSuperset(of: ["chat", "message", "chat_message_join", "handle"]) else {
            throw RelayError.message("The selected file does not contain a supported Messages snapshot.")
        }
        let resultValue = try read(handle)
        guard try version(of: url) == before,
              !["-wal", "-journal"].contains(where: { FileManager.default.fileExists(atPath: path + $0) }) else {
            throw RelayError.message("The selected Messages snapshot changed during reading.")
        }
        return resultValue
    }

    private static func query<T>(_ database: OpaquePointer, sql: String, bind: (OpaquePointer) -> Bool = { _ in true },
                                 map: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement, bind(statement) else {
            throw RelayError.message("This Messages database schema is not supported.")
        }
        var output: [T] = []
        while true {
            try Task.checkCancellation()
            switch sqlite3_step(statement) {
            case SQLITE_ROW: output.append(map(statement))
            case SQLITE_DONE: return output
            default: throw RelayError.message("The selected snapshot could not be read completely.")
            }
        }
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(row, column) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, column))), as: UTF8.self)
    }
}

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
    let incomingHandle: String?

    init(time: String, sender: String, body: String, incomingHandle: String? = nil) {
        self.time = time
        self.sender = sender
        self.body = body
        self.incomingHandle = incomingHandle
    }
}

nonisolated struct MessagesArchiveRead: Sendable {
    let entries: [ChatArchiveEntry]
    let omittedAttributedBodies: Int
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

    static func isStandaloneMessages(_ url: URL) -> Bool {
        !["-wal", "-journal"].contains { FileManager.default.fileExists(atPath: url.path + $0) }
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
        guard let parsed = try WhatsAppExportReader.parse(text) else {
            throw RelayError.message("No supported WhatsApp message lines were found in this export.")
        }
        return parsed.entries
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

    @concurrent static func messages(_ url: URL, chatID: Int64, days: Int, now: Date = Date(),
                                     includeIncomingHandles: Bool = false) async throws -> MessagesArchiveRead {
        guard chatID > 0, (1...365).contains(days) else { throw RelayError.message("Choose a conversation and a time range of 1 to 365 days.") }
        let appleEpoch: TimeInterval = 978_307_200
        let current = now.timeIntervalSince1970 - appleEpoch
        guard current.isFinite, (-1_000_000_000...20_000_000_000).contains(current) else {
            throw RelayError.message("The date range for this Messages snapshot is invalid.")
        }
        let upper = Int64(current)
        let cutoff = upper - Int64(days * 86_400)
        return try withDatabase(url) { db in
            let attributedColumns = try query(db, sql: "PRAGMA main.table_xinfo('message')") { row in
                sqlite3_column_int(row, 6) == 0 && text(row, 1)?.lowercased() == "attributedbody"
            }
            let hasAttributedBody = attributedColumns.contains(true)
            let plain = "m.text IS NOT NULL AND length(m.text) > 0"
            let candidate = hasAttributedBody ? "(\(plain)) OR m.attributedBody IS NOT NULL" : plain
            let attributed = hasAttributedBody ? """
                CASE WHEN NOT (\(plain)) AND typeof(m.attributedBody) = 'blob'
                          AND length(m.attributedBody) BETWEEN 1 AND \(MessagesAttributedBody.maximumArchiveBytes)
                     THEN m.attributedBody END
                """ : "NULL"
            let handle = includeIncomingHandles ? """
                CASE WHEN m.is_from_me = 0 AND typeof(h.id) = 'text'
                          AND length(CAST(h.id AS BLOB)) BETWEEN 1 AND \(MessagesArchiveContacts.maximumHandleBytes)
                     THEN h.id END
                """ : "NULL"
            // Bound the selected window before SQLite projects any body payloads.
            let rows: [ChatArchiveEntry?] = try query(db, sql: """
                WITH recent AS MATERIALIZED (
                    SELECT m.rowid AS message_id,
                           CASE WHEN abs(m.date) > 100000000000 THEN m.date / 1000000000 ELSE m.date END AS timestamp
                      FROM chat_message_join j
                      JOIN message m ON m.rowid = j.message_id
                     WHERE j.chat_id = ?1 AND (\(candidate))
                       AND (CASE WHEN abs(m.date) > 100000000000 THEN m.date / 1000000000 ELSE m.date END) BETWEEN ?2 AND ?3
                     ORDER BY timestamp DESC, m.rowid DESC LIMIT \(maximumEntries)
                )
                SELECT recent.timestamp, m.is_from_me, substr(h.id, 1, 180),
                       substr(m.text, 1, \(MessagesAttributedBody.maximumBodyScalars)), \(attributed), \(handle)
                  FROM recent
                  JOIN message m ON m.rowid = recent.message_id
                  LEFT JOIN handle h ON h.rowid = m.handle_id
                 ORDER BY recent.timestamp DESC, m.rowid DESC
                """, bind: { row in
                    sqlite3_bind_int64(row, 1, chatID) == SQLITE_OK && sqlite3_bind_int64(row, 2, cutoff) == SQLITE_OK
                        && sqlite3_bind_int64(row, 3, upper) == SQLITE_OK
                }) { row in
                    let plainBody = text(row, 3)
                    let body = if let plainBody, !plainBody.isEmpty { plainBody }
                               else { attributedBody(row, 4) }
                    guard let body else { return nil }
                    let time = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(row, 0)) + appleEpoch)
                    return ChatArchiveEntry(time: time.ISO8601Format(),
                        sender: sqlite3_column_int(row, 1) != 0 ? "Me" : text(row, 2) ?? "Participant",
                        body: body, incomingHandle: exactText(row, 5))
                }
            let entries = rows.reversed().compactMap { $0 }
            let omitted = rows.count - entries.count
            guard !entries.isEmpty else {
                if omitted > 0 {
                    let unit = omitted == 1 ? "body" : "bodies"
                    throw RelayError.message("No supported message text was available. Skipped \(omitted) unsupported message \(unit).")
                }
                throw RelayError.message("No message text was available in this conversation and time range.")
            }
            return MessagesArchiveRead(entries: entries, omittedAttributedBodies: omitted)
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
        guard isStandaloneMessages(url) else {
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
              isStandaloneMessages(url) else {
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

    private static func attributedBody(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(row, column) == SQLITE_BLOB else { return nil }
        let count = Int(sqlite3_column_bytes(row, column))
        guard (1...MessagesAttributedBody.maximumArchiveBytes).contains(count),
              let bytes = sqlite3_column_blob(row, column) else { return nil }
        return MessagesAttributedBody.decode(Data(bytes: bytes, count: count))
    }

    private static func exactText(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(row, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(row, column) else { return nil }
        let count = Int(sqlite3_column_bytes(row, column))
        guard (1...MessagesArchiveContacts.maximumHandleBytes).contains(count) else { return nil }
        return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(row, column) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, column))), as: UTF8.self)
    }
}

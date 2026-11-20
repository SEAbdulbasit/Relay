import AppKit
import Compression
import Contacts
import CryptoKit
import Darwin
import Foundation
import Observation
import SQLite3

// MARK: - Source Kinds, Paths & Full Disk Access Detection

nonisolated enum LiveLocalSourceKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case notes
    case appleMail = "apple_mail"
    case imessage
    case whatsapp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "Apple Notes"
        case .appleMail: "Apple Mail"
        case .imessage: "iMessage"
        case .whatsapp: "WhatsApp"
        }
    }

    var subtitle: String {
        switch self {
        case .notes: "Incremental SQLite ingestion of local notes with exact item checkpoints."
        case .appleMail: "Primary & sent mail from Envelope Index + .emlx, skipping Junk, Trash, Drafts, and bulk."
        case .imessage: "Opt-in conversations from chat.db with attributedBody decoding and Contacts resolution."
        case .whatsapp: "Opt-in DMs and groups from local ChatStorage.sqlite with member & push-name resolution."
        }
    }

    var checkpointBucketPrefix: String {
        switch self {
        case .notes: "notes"
        case .appleMail: "apple_mail"
        case .imessage: "imessage:"
        case .whatsapp: "whatsapp:"
        }
    }
}

nonisolated struct LiveLocalSourcePaths: Sendable, Equatable {
    var notesDatabaseURL: URL
    var messagesDatabaseURL: URL
    var whatsappDatabaseURL: URL
    var mailRootURL: URL
    var addressBookRootURL: URL
    var fdaProbePaths: [(label: String, path: String)]

    static func == (lhs: LiveLocalSourcePaths, rhs: LiveLocalSourcePaths) -> Bool {
        lhs.notesDatabaseURL == rhs.notesDatabaseURL
            && lhs.messagesDatabaseURL == rhs.messagesDatabaseURL
            && lhs.whatsappDatabaseURL == rhs.whatsappDatabaseURL
            && lhs.mailRootURL == rhs.mailRootURL
            && lhs.addressBookRootURL == rhs.addressBookRootURL
            && lhs.fdaProbePaths.map(\.path) == rhs.fdaProbePaths.map(\.path)
    }

    static var defaultLivePaths: LiveLocalSourcePaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let messages = home.appending(path: "Library/Messages/chat.db")
        let safari = home.appending(path: "Library/Safari/Bookmarks.plist")
        let tcc = home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db")
        return LiveLocalSourcePaths(
            notesDatabaseURL: home.appending(path: "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"),
            messagesDatabaseURL: messages,
            whatsappDatabaseURL: home.appending(path: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"),
            mailRootURL: home.appending(path: "Library/Mail", directoryHint: .isDirectory),
            addressBookRootURL: home.appending(path: "Library/Application Support/AddressBook", directoryHint: .isDirectory),
            fdaProbePaths: [
                ("messages", messages.path),
                ("safari", safari.path),
                ("tcc", tcc.path)
            ]
        )
    }
}

nonisolated struct FullDiskAccessStatus: Sendable, Equatable {
    let granted: Bool
    let matchedProbe: String
    let errnoCode: Int32

    static let modernSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
    static let legacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var guidanceSummary: String {
        if granted {
            return "Full Disk Access is active (\(matchedProbe)). Live checkpointed local databases are readable."
        }
        if errnoCode == EPERM || errnoCode == EACCES {
            return "Grant Full Disk Access in System Settings → Privacy & Security → Full Disk Access to enable live incremental Notes, Mail, and iMessage database sync. Session highlight capture and standalone backup imports continue to work without it."
        }
        return "No TCC-protected local database was readable yet. Grant Full Disk Access in System Settings to enable live incremental database sync."
    }
}

nonisolated enum FullDiskAccessDetector {
    static func probe(paths: [(label: String, path: String)] = LiveLocalSourcePaths.defaultLivePaths.fdaProbePaths) -> FullDiskAccessStatus {
        var denied: (String, Int32)?
        for (label, path) in paths {
            let fd = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
            if fd >= 0 {
                Darwin.close(fd)
                return FullDiskAccessStatus(granted: true, matchedProbe: label, errnoCode: 0)
            }
            let code = errno
            if code != ENOENT, denied == nil {
                denied = (label, code)
            }
        }
        if let (label, code) = denied {
            return FullDiskAccessStatus(granted: false, matchedProbe: label, errnoCode: code)
        }
        return FullDiskAccessStatus(granted: false, matchedProbe: "none", errnoCode: ENOENT)
    }

    @MainActor
    @discardableResult
    static func openSystemSettings(openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        if openURL(FullDiskAccessStatus.modernSettingsURL) {
            return true
        }
        return openURL(FullDiskAccessStatus.legacySettingsURL)
    }
}

// MARK: - Durable Per-Source & Per-Bucket Checkpoints (TRI-05, TRI-06)

nonisolated struct LiveIngestedItem: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let source: LiveLocalSourceKind
    let bucket: String
    let title: String
    let subtitle: String
    let body: String
    let timestamp: Date
    let orderKey: Double
    let contentDigest: String

    func toKnowledgeRecord() -> KnowledgeRecord {
        let header = subtitle.isEmpty ? title : "\(title)\n\(subtitle)"
        let combined = "\(header)\n\n\(body)"
        return KnowledgeRecord(
            sourcePath: "relay-live://\(source.rawValue)/\(id)",
            title: title,
            text: combined,
            modifiedAt: timestamp,
            contentHash: contentDigest,
            byteCount: combined.utf8.count,
            coverageNote: "Live \(source.title) incremental sync",
            sourceIdentity: bucket,
            sourceUpdatedAt: timestamp
        )
    }

    func toNativePersonalSourceItem() -> NativePersonalSourceItem {
        let truncated = body.utf8.count > 8_192
        return NativePersonalSourceItem(
            id: id,
            title: title,
            sender: subtitle.isEmpty ? nil : subtitle,
            text: NativePersonalSources.bounded(body, maximumBytes: 8_192),
            textLimited: truncated,
            sentAt: nil,
            receivedAt: timestamp,
            notesAttribution: source == .notes
                ? NativeNotesAttribution(noteID: id, folder: subtitle, createdAt: timestamp, updatedAt: timestamp)
                : nil
        )
    }
}

nonisolated struct LiveWritingSample: Codable, Sendable, Equatable {
    let source: LiveLocalSourceKind
    let recipient: String
    let subject: String?
    let text: String
    let sentAt: Date?
}

nonisolated struct LiveChatDescriptor: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let source: LiveLocalSourceKind
    let title: String
    let participantSummary: String
    let isGroup: Bool
    let messageCount: Int
    let lastMessageAt: Date?
}

nonisolated struct LiveMailAccountDescriptor: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let mailboxCount: Int
}

nonisolated final class LiveSourceCheckpointStore: @unchecked Sendable {
    struct ItemKey: Codable, Comparable, Sendable, Equatable {
        let order: Double
        let tiebreak: String

        static func < (lhs: ItemKey, rhs: ItemKey) -> Bool {
            lhs.order == rhs.order ? lhs.tiebreak < rhs.tiebreak : lhs.order < rhs.order
        }
    }

    struct BucketCursor: Codable, Sendable, Equatable {
        var mark: ItemKey
        var floor: ItemKey?
        var processedCount: Int
        var updatedAt: Date
    }

    struct MailReceipt: Codable, Sendable, Equatable {
        static let currentVersion = 1
        let version: Int
        let contentDigest: String
        let ingestedAt: Date
    }

    private struct PersistedState: Codable {
        static let currentVersion = 1
        var version = Self.currentVersion
        var buckets: [String: BucketCursor] = [:]
        var mailCheckpoints: [String: MailIngestion.Checkpoint] = [:]
        var mailReceipts: [String: MailReceipt] = [:]
    }

    static let maximumStateBytes = 8 * 1_024 * 1_024

    private let lock = NSLock()
    private let fileURL: URL?
    private var state = PersistedState()
    private var batchingEnabled = false
    private var dirtyMutations = 0

    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Relay", directoryHint: .isDirectory)
            .appending(path: "live-source-checkpoints.json")
    }

    init(fileURL: URL? = LiveSourceCheckpointStore.defaultURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? LocalStateFile.read(fileURL, maximumBytes: Self.maximumStateBytes),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data),
           decoded.version == PersistedState.currentVersion {
            self.state = decoded
        }
    }

    func setBatchingEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        batchingEnabled = enabled
    }

    var hasUnflushedChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dirtyMutations > 0
    }

    func flush() throws {
        lock.lock()
        defer { lock.unlock() }
        guard dirtyMutations > 0 else { return }
        try persistLocked()
        dirtyMutations = 0
    }

    func cursor(for bucket: String) -> BucketCursor? {
        lock.lock()
        defer { lock.unlock() }
        return state.buckets[bucket]
    }

    func allBuckets() -> [String: BucketCursor] {
        lock.lock()
        defer { lock.unlock() }
        return state.buckets
    }

    func advance(bucket: String, to key: ItemKey, initialFloor: ItemKey? = nil, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        if var existing = state.buckets[bucket] {
            if existing.mark < key {
                existing.mark = key
            }
            existing.processedCount += 1
            existing.updatedAt = now
            state.buckets[bucket] = existing
        } else {
            state.buckets[bucket] = BucketCursor(
                mark: key,
                floor: initialFloor ?? key,
                processedCount: 1,
                updatedAt: now
            )
        }
        try markDirtyOrPersistLocked()
    }

    func sinkFloor(bucket: String, to key: ItemKey, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var existing = state.buckets[bucket] else { return }
        if let currentFloor = existing.floor {
            if key < currentFloor {
                existing.floor = key
            }
        } else {
            existing.floor = key
        }
        existing.processedCount += 1
        existing.updatedAt = now
        state.buckets[bucket] = existing
        try markDirtyOrPersistLocked()
    }

    func collapseFloor(bucket: String, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var existing = state.buckets[bucket], existing.floor != nil else { return }
        existing.floor = nil
        existing.updatedAt = now
        state.buckets[bucket] = existing
        try markDirtyOrPersistLocked()
    }

    func mailCheckpoint(for accountKey: String = "default") -> MailIngestion.Checkpoint? {
        lock.lock()
        defer { lock.unlock() }
        return state.mailCheckpoints[accountKey]
    }

    func mailReceipt(for itemID: String) -> MailReceipt? {
        lock.lock()
        defer { lock.unlock() }
        return state.mailReceipts[itemID]
    }

    func commitMailCheckpoint(_ checkpoint: MailIngestion.Checkpoint, accountKey: String = "default",
                              receipt: (id: String, digest: String, at: Date)? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        state.mailCheckpoints[accountKey] = checkpoint
        if let receipt {
            state.mailReceipts[receipt.id] = MailReceipt(
                version: MailReceipt.currentVersion,
                contentDigest: receipt.digest,
                ingestedAt: receipt.at
            )
        }
        try markDirtyOrPersistLocked()
    }

    func wipeBucket(_ bucket: String) throws {
        lock.lock()
        defer { lock.unlock() }
        state.buckets.removeValue(forKey: bucket)
        dirtyMutations = 0
        try persistLocked()
    }

    func wipeSource(_ kind: LiveLocalSourceKind) throws {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .notes:
            state.buckets.removeValue(forKey: "notes")
        case .appleMail:
            state.mailCheckpoints.removeAll()
            state.mailReceipts.removeAll()
        case .imessage:
            state.buckets = state.buckets.filter { !$0.key.hasPrefix("imessage:") }
        case .whatsapp:
            state.buckets = state.buckets.filter { !$0.key.hasPrefix("whatsapp:") }
        }
        dirtyMutations = 0
        try persistLocked()
    }

    func wipeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        state = PersistedState()
        dirtyMutations = 0
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func markDirtyOrPersistLocked() throws {
        if batchingEnabled {
            dirtyMutations += 1
        } else {
            dirtyMutations = 0
            try persistLocked()
        }
    }

    private func persistLocked() throws {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try LocalPrivateFileWriter.write(data: data, to: fileURL, maximumBytes: Self.maximumStateBytes)
    }
}

// MARK: - SQLite Snapshot & Reader Utilities

nonisolated enum LiveLocalSourceError: LocalizedError, Equatable {
    case fullDiskAccessRequired(String)
    case sourceDatabaseMissing(String)
    case snapshotFailed(String)
    case queryFailed(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired(let source):
            return "Grant Full Disk Access in System Settings to read \(source)."
        case .sourceDatabaseMissing(let source):
            return "\(source) database was not found on this Mac."
        case .snapshotFailed(let detail):
            return "Could not prepare a safe local snapshot: \(detail)"
        case .queryFailed(let detail):
            return "Local database read failed: \(detail)"
        case .busy:
            return "A local source sync is already running."
        }
    }
}

nonisolated enum LiveSourceSQLite {
    static let appleEpochOffset: TimeInterval = 978_307_200

    static func appleDate(_ secondsOrNanoseconds: Double) -> Date {
        let seconds: Double
        if abs(secondsOrNanoseconds) > 100_000_000_000 {
            seconds = secondsOrNanoseconds / 1_000_000_000
        } else {
            seconds = secondsOrNanoseconds
        }
        return Date(timeIntervalSince1970: seconds + appleEpochOffset)
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func makePrivateTempDirectory(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Copies the SQLite database plus any readable `-wal` and `-shm` companions into a private 0700 temp directory (`SRC-24`).
    static func walSafeCopy(of path: String, label: String, requireCompleteWAL: Bool = true) throws -> (dbURL: URL, tempDir: URL) {
        let fm = FileManager.default
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        if fd < 0 {
            let code = errno
            if code == EPERM || code == EACCES {
                throw LiveLocalSourceError.fullDiskAccessRequired(label)
            }
            throw LiveLocalSourceError.sourceDatabaseMissing(label)
        }
        Darwin.close(fd)

        let tempDir = try makePrivateTempDirectory(prefix: "relay-live-sqlite")
        let sourceURL = URL(fileURLWithPath: path)
        let sourceDir = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.lastPathComponent
        let destDB = tempDir.appending(path: baseName)
        do {
            try fm.copyItem(atPath: path, toPath: destDB.path)
            _ = chmod(destDB.path, 0o600)
            for suffix in ["-wal", "-shm"] {
                let sidecar = sourceDir.appending(path: baseName + suffix).path
                let sidecarFD = sidecar.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
                guard sidecarFD >= 0 else { continue }
                Darwin.close(sidecarFD)
                let destSidecar = tempDir.appending(path: baseName + suffix).path
                do {
                    try fm.copyItem(atPath: sidecar, toPath: destSidecar)
                    _ = chmod(destSidecar, 0o600)
                } catch {
                    if suffix == "-wal", requireCompleteWAL, fm.isReadableFile(atPath: sidecar) {
                        throw LiveLocalSourceError.snapshotFailed("Incomplete WAL journal for \(label).")
                    }
                }
            }
            return (destDB, tempDir)
        } catch {
            try? fm.removeItem(at: tempDir)
            if let liveError = error as? LiveLocalSourceError { throw liveError }
            throw LiveLocalSourceError.snapshotFailed(error.localizedDescription)
        }
    }

    /// Stages a WAL-complete temp snapshot (`<filename>`, `<filename>-wal`, `<filename>-shm`) first (`SRC-24`)
    /// so the live database directory is never opened directly, then consolidates into a standalone SQLite backup.
    static func onlineBackup(of path: String, label: String, maxPages: Int32 = 262_144) throws -> (dbURL: URL, tempDir: URL) {
        let (stagedDB, tempDir) = try walSafeCopy(of: path, label: label)
        let destDB = tempDir.appending(path: "EnvelopeIndexSnapshot.sqlite")

        var src: OpaquePointer?
        guard sqlite3_open_v2(stagedDB.path, &src, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let src else {
            if let src { sqlite3_close(src) }
            try? FileManager.default.removeItem(at: tempDir)
            throw LiveLocalSourceError.snapshotFailed("Could not open \(label).")
        }
        defer { sqlite3_close(src) }
        sqlite3_busy_timeout(src, 2_500)

        var dst: OpaquePointer?
        guard sqlite3_open_v2(destDB.path, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let dst else {
            if let dst { sqlite3_close(dst) }
            try? FileManager.default.removeItem(at: tempDir)
            throw LiveLocalSourceError.snapshotFailed("Could not create temporary backup for \(label).")
        }
        _ = chmod(destDB.path, 0o600)

        guard let backup = sqlite3_backup_init(dst, "main", src, "main") else {
            sqlite3_close(dst)
            try? FileManager.default.removeItem(at: tempDir)
            throw LiveLocalSourceError.snapshotFailed("Could not initialize SQLite backup for \(label).")
        }

        var stepRC: Int32 = SQLITE_OK
        while true {
            if Task.isCancelled {
                _ = sqlite3_backup_finish(backup)
                sqlite3_close(dst)
                try? FileManager.default.removeItem(at: tempDir)
                throw CancellationError()
            }
            stepRC = sqlite3_backup_step(backup, 256)
            if stepRC == SQLITE_DONE { break }
            if stepRC == SQLITE_BUSY || stepRC == SQLITE_LOCKED {
                usleep(20_000)
                continue
            }
            if stepRC != SQLITE_OK { break }
            if sqlite3_backup_pagecount(backup) > maxPages {
                _ = sqlite3_backup_finish(backup)
                sqlite3_close(dst)
                try? FileManager.default.removeItem(at: tempDir)
                throw LiveLocalSourceError.snapshotFailed("\(label) exceeds page cap.")
            }
        }
        let finishRC = sqlite3_backup_finish(backup)
        sqlite3_close(dst)
        guard stepRC == SQLITE_DONE, finishRC == SQLITE_OK else {
            try? FileManager.default.removeItem(at: tempDir)
            throw LiveLocalSourceError.snapshotFailed("SQLite backup incomplete for \(label) (rc=\(finishRC)).")
        }
        return (destDB, tempDir)
    }

    final class Reader {
        let db: OpaquePointer

        init(path: String, readOnly: Bool = true) throws {
            var handle: OpaquePointer?
            let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX
            guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }
                throw LiveLocalSourceError.queryFailed("Failed opening SQLite snapshot.")
            }
            self.db = handle
            sqlite3_busy_timeout(handle, 2_000)
        }

        deinit {
            sqlite3_close(db)
        }

        func tableColumns(_ table: String) -> Set<String> {
            var cols = Set<String>()
            guard !table.isEmpty,
                  table.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else {
                return cols
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return cols
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 1) {
                    cols.insert(String(cString: cStr))
                }
            }
            return cols
        }

        func query(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }, row: (OpaquePointer) throws -> Void) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                let message = String(cString: sqlite3_errmsg(db))
                throw LiveLocalSourceError.queryFailed(message)
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt)
            while true {
                try Task.checkCancellation()
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    try row(stmt)
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    let message = String(cString: sqlite3_errmsg(db))
                    throw LiveLocalSourceError.queryFailed(message)
                }
            }
        }

        static func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
            guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
                  let ptr = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: ptr)
        }

        static func int64(_ stmt: OpaquePointer, _ col: Int32) -> Int64 {
            sqlite3_column_int64(stmt, col)
        }

        static func double(_ stmt: OpaquePointer, _ col: Int32) -> Double {
            sqlite3_column_double(stmt, col)
        }

        static func blob(_ stmt: OpaquePointer, _ col: Int32, maxBytes: Int = 2 * 1_024 * 1_024) -> Data? {
            guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, col))
            guard count > 0, count <= maxBytes, let ptr = sqlite3_column_blob(stmt, col) else { return nil }
            return Data(bytes: ptr, count: count)
        }
    }
}

// MARK: - Conversation Windowing & Typedstream / AddressBook Decoders

nonisolated enum LiveChatWindowing {
    static let maxWindowUTF8Bytes = 12_000
    static let lookbackSeconds: TimeInterval = 90 * 24 * 60 * 60
    static let maxMessagesPerQuery = 100_000

    struct MessageEntry: Sendable, Equatable {
        let id: String
        let orderKey: Double
        let timestamp: Date
        let sender: String
        let isFromMe: Bool
        let text: String

        var formattedLine: String {
            let iso = LiveChatWindowing.timestampString(timestamp)
            return "[\(iso)] \(sender): \(text)"
        }
    }

    struct Window: Sendable, Equatable {
        let chatID: String
        let chatTitle: String
        let bucket: String
        let entries: [MessageEntry]

        var firstKey: LiveSourceCheckpointStore.ItemKey {
            let first = entries.first!
            return .init(order: first.orderKey, tiebreak: first.id)
        }

        var lastKey: LiveSourceCheckpointStore.ItemKey {
            let last = entries.last!
            return .init(order: last.orderKey, tiebreak: last.id)
        }

        var combinedText: String {
            entries.map(\.formattedLine).joined(separator: "\n")
        }
    }

    static func timestampString(_ date: Date) -> String {
        var seconds = time_t(floor(date.timeIntervalSince1970))
        var utc = tm()
        gmtime_r(&seconds, &utc)
        let year = Int(utc.tm_year) + 1900
        let month = Int(utc.tm_mon) + 1
        let day = Int(utc.tm_mday)
        let hour = Int(utc.tm_hour)
        let minute = Int(utc.tm_min)
        let second = Int(utc.tm_sec)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, hour, minute, second)
    }

    /// Groups chronologically ascending messages into <=12KB UTF-8 conversation windows.
    static func buildWindows(chatID: String, chatTitle: String, bucket: String, messages: [MessageEntry]) -> [Window] {
        guard !messages.isEmpty else { return [] }
        let sorted = messages.sorted {
            $0.orderKey == $1.orderKey ? $0.id < $1.id : $0.orderKey < $1.orderKey
        }
        var windows: [Window] = []
        var current: [MessageEntry] = []
        var currentBytes = 0

        for entry in sorted {
            let boundedText = NativePersonalSources.bounded(entry.text, maximumBytes: maxWindowUTF8Bytes - 256)
            let normalized = MessageEntry(
                id: entry.id,
                orderKey: entry.orderKey,
                timestamp: entry.timestamp,
                sender: entry.sender,
                isFromMe: entry.isFromMe,
                text: boundedText
            )
            let lineBytes = normalized.formattedLine.utf8.count + 1
            if !current.isEmpty, currentBytes + lineBytes > maxWindowUTF8Bytes {
                windows.append(Window(chatID: chatID, chatTitle: chatTitle, bucket: bucket, entries: current))
                current = [normalized]
                currentBytes = lineBytes
            } else {
                current.append(normalized)
                currentBytes += lineBytes
            }
        }
        if !current.isEmpty {
            windows.append(Window(chatID: chatID, chatTitle: chatTitle, bucket: bucket, entries: current))
        }
        return windows
    }

    /// Filters windows into `forward` (newer than `mark`, oldest-first) and `backfill` (older than `floor`, newest-first).
    static func partition(windows: [Window], cursor: LiveSourceCheckpointStore.BucketCursor?) -> (forward: [Window], backfill: [Window], initialFloor: LiveSourceCheckpointStore.ItemKey?) {
        guard !windows.isEmpty else { return ([], [], nil) }
        guard let cursor else {
            // First run: process newest-first so recent context lands immediately while floor sinks downward!
            let newestFirst = Array(windows.reversed())
            return ([], newestFirst, newestFirst.first?.lastKey)
        }
        let forward = windows.filter { $0.lastKey > cursor.mark }
        let backfill: [Window]
        if let floor = cursor.floor {
            backfill = windows.filter { $0.lastKey < floor }.reversed()
        } else {
            backfill = []
        }
        return (forward, backfill, nil)
    }
}

nonisolated enum LiveMessageBodyDecoder {
    /// Decodes `attributedBody` using Relay's strict `MessagesAttributedBody` parser first,
    /// then falls back to Sentient OS 3.1's typedstream `NSString`/`NSMutableString` preamble scanner
    /// so rich/multi-part messages (links, mentions, formatting runs) also decode cleanly.
    static func decode(plainText: String?, attributedBody: Data?) -> String? {
        if let plainText {
            let cleaned = cleanText(plainText)
            if !cleaned.isEmpty { return cleaned }
        }
        guard let attributedBody, !attributedBody.isEmpty else { return nil }
        if let strict = MessagesAttributedBody.decode(attributedBody) {
            let cleaned = cleanText(strict)
            if !cleaned.isEmpty { return cleaned }
        }
        if let scanned = scanTypedstream(attributedBody) {
            let cleaned = cleanText(scanned)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    static func scanTypedstream(_ data: Data) -> String? {
        guard data.count <= 256 * 1_024 else { return nil }
        let bytes = [UInt8](data)
        let markers: [[UInt8]] = [
            Array("NSMutableString".utf8),
            Array("NSString".utf8)
        ]
        for marker in markers {
            guard bytes.count > marker.count + 6 else { continue }
            var index = 0
            while index <= bytes.count - marker.count - 6 {
                if Array(bytes[index..<(index + marker.count)]) == marker {
                    let after = index + marker.count
                    // Standard typedstream 5-byte preamble: 0x01, (0x94|0x95), 0x84, 0x01, 0x2B ('+')
                    if after + 5 < bytes.count,
                       bytes[after] == 0x01,
                       (bytes[after + 1] == 0x94 || bytes[after + 1] == 0x95),
                       bytes[after + 2] == 0x84,
                       bytes[after + 3] == 0x01,
                       bytes[after + 4] == 0x2B {
                        var cursor = after + 5
                        if let length = readTypedstreamLength(bytes, cursor: &cursor),
                           length > 0, cursor + length <= bytes.count,
                           let decoded = String(bytes: bytes[cursor..<(cursor + length)], encoding: .utf8) {
                            return decoded
                        }
                    }
                    // Reference-table variant where '+' (0x2B) directly precedes length-prefixed UTF-8
                    for probe in after..<min(after + 12, bytes.count - 1) where bytes[probe] == 0x2B {
                        var cursor = probe + 1
                        if let length = readTypedstreamLength(bytes, cursor: &cursor),
                           length > 0, cursor + length <= bytes.count,
                           let decoded = String(bytes: bytes[cursor..<(cursor + length)], encoding: .utf8) {
                            return decoded
                        }
                    }
                }
                index += 1
            }
        }
        return nil
    }

    private static func readTypedstreamLength(_ bytes: [UInt8], cursor: inout Int) -> Int? {
        guard cursor < bytes.count else { return nil }
        let first = bytes[cursor]
        cursor += 1
        if first < 0x80 {
            return Int(first)
        }
        switch first {
        case 0x81:
            guard cursor + 2 <= bytes.count else { return nil }
            let value = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
            cursor += 2
            return value
        case 0x82:
            guard cursor + 4 <= bytes.count else { return nil }
            let value = Int(bytes[cursor])
                | (Int(bytes[cursor + 1]) << 8)
                | (Int(bytes[cursor + 2]) << 16)
                | (Int(bytes[cursor + 3]) << 24)
            cursor += 4
            return value
        default:
            return nil
        }
    }

    static func cleanText(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped
    }
}

nonisolated enum LiveAddressBookResolver {
    private struct CachedContactMap {
        let signature: String
        let map: [String: String]
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedMaps: [String: CachedContactMap] = [:]

    static func loadMap(addressBookRoot: URL) -> [String: String] {
        let fm = FileManager.default
        var candidateDBs: [URL] = []

        let rootDB = addressBookRoot.appending(path: "AddressBook-v22.abcddb")
        if fm.fileExists(atPath: rootDB.path) {
            candidateDBs.append(rootDB)
        }
        let sourcesDir = addressBookRoot.appending(path: "Sources", directoryHint: .isDirectory)
        if let subdirs = try? fm.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for dir in subdirs.sorted(by: { $0.path < $1.path }) {
                let db = dir.appending(path: "AddressBook-v22.abcddb")
                if fm.fileExists(atPath: db.path) {
                    candidateDBs.append(db)
                }
            }
        }

        let signature = candidateDBs.map { dbURL -> String in
            let dbPath = dbURL.path
            let walPath = dbPath + "-wal"
            let dbMtime = (try? fm.attributesOfItem(atPath: dbPath)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let walMtime = (try? fm.attributesOfItem(atPath: walPath)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(dbPath):\(dbMtime):\(walMtime)"
        }.joined(separator: "|")

        let cacheKey = addressBookRoot.standardizedFileURL.path
        cacheLock.lock()
        if let hit = cachedMaps[cacheKey], hit.signature == signature {
            cacheLock.unlock()
            return hit.map
        }
        cacheLock.unlock()

        var map: [String: String] = [:]
        for dbURL in candidateDBs {
            guard let (copyURL, tempDir) = try? LiveSourceSQLite.walSafeCopy(of: dbURL.path, label: "Contacts", requireCompleteWAL: false) else {
                continue
            }
            defer { try? fm.removeItem(at: tempDir) }
            guard let reader = try? LiveSourceSQLite.Reader(path: copyURL.path) else { continue }

            var namesByPK: [Int64: String] = [:]
            try? reader.query("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION, ZNICKNAME FROM ZABCDRECORD") { stmt in
                let pk = LiveSourceSQLite.Reader.int64(stmt, 0)
                let first = LiveSourceSQLite.Reader.text(stmt, 1)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let last = LiveSourceSQLite.Reader.text(stmt, 2)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let org = LiveSourceSQLite.Reader.text(stmt, 3)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let nick = LiveSourceSQLite.Reader.text(stmt, 4)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
                let chosen = !full.isEmpty ? full : (!nick.isEmpty ? nick : org)
                if !chosen.isEmpty {
                    namesByPK[pk] = chosen
                }
            }

            try? reader.query("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER WHERE ZFULLNUMBER IS NOT NULL") { stmt in
                let owner = LiveSourceSQLite.Reader.int64(stmt, 0)
                guard let name = namesByPK[owner], let rawPhone = LiveSourceSQLite.Reader.text(stmt, 1) else { return }
                for key in phoneKeys(rawPhone) where map[key] == nil {
                    map[key] = name
                }
            }

            try? reader.query("SELECT ZOWNER, ZADDRESSNORMALIZED, ZADDRESS FROM ZABCDEMAILADDRESS") { stmt in
                let owner = LiveSourceSQLite.Reader.int64(stmt, 0)
                guard let name = namesByPK[owner] else { return }
                let raw = LiveSourceSQLite.Reader.text(stmt, 1) ?? LiveSourceSQLite.Reader.text(stmt, 2)
                if let email = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty, map[email] == nil {
                    map[email] = name
                }
            }
        }

        cacheLock.lock()
        cachedMaps[cacheKey] = CachedContactMap(signature: signature, map: map)
        cacheLock.unlock()
        return map
    }

    static func resolve(_ handle: String, in map: [String: String]) -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("@") {
            return map[trimmed.lowercased()]
        }
        for key in phoneKeys(trimmed) {
            if let found = map[key] { return found }
        }
        return nil
    }

    private static func phoneKeys(_ raw: String) -> [String] {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return [] }
        var keys = [digits]
        if digits.count > 10 {
            keys.append(String(digits.suffix(10)))
        }
        if digits.count == 10 {
            keys.append("1" + digits)
        }
        return keys
    }
}

// MARK: - 1. Live Apple Notes Reader (`NoteStore.sqlite`)

nonisolated enum LiveAppleNotesReader {
    static let maxNotesWindow = 1_000

    struct NoteCandidate: Sendable {
        let identifier: String
        let title: String
        let folder: String
        let body: String
        let createdOrder: Double
        let modifiedDate: Date

        var itemKey: LiveSourceCheckpointStore.ItemKey {
            .init(order: createdOrder, tiebreak: "notes:\(identifier)")
        }
    }

    static func readIncremental(
        databaseURL: URL,
        checkpointStore: LiveSourceCheckpointStore,
        maxItemsPerPass: Int = 250,
        onItem: (LiveIngestedItem) async throws -> Void,
        onCheckpointAdvanced: () async throws -> Void = {}
    ) async throws -> Int {
        let (copyURL, tempDir) = try LiveSourceSQLite.walSafeCopy(of: databaseURL.path, label: "Apple Notes")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let candidates = try loadCandidates(snapshotURL: copyURL)
        let cursor = checkpointStore.cursor(for: "notes")

        let forward: [NoteCandidate]
        let backfill: [NoteCandidate]
        let initialFloor: LiveSourceCheckpointStore.ItemKey?

        if let cursor {
            forward = candidates
                .filter { $0.itemKey > cursor.mark }
                .sorted { $0.itemKey < $1.itemKey }
            if let floor = cursor.floor {
                backfill = candidates
                    .filter { $0.itemKey < floor }
                    .sorted { $1.itemKey < $0.itemKey }
            } else {
                backfill = []
            }
            initialFloor = nil
        } else {
            forward = []
            backfill = candidates.sorted { $1.itemKey < $0.itemKey }
            initialFloor = backfill.first?.itemKey
        }

        var ingested = 0

        for note in forward {
            try Task.checkCancellation()
            guard ingested < maxItemsPerPass else { return ingested }
            let item = makeIngestedItem(note)
            try await onItem(item)
            try checkpointStore.advance(bucket: "notes", to: note.itemKey)
            ingested += 1
            if ingested % LiveLocalSourcesCoordinator.checkpointBatchSize == 0 {
                try await onCheckpointAdvanced()
            }
        }

        for note in backfill {
            try Task.checkCancellation()
            guard ingested < maxItemsPerPass else { return ingested }
            let item = makeIngestedItem(note)
            try await onItem(item)
            if checkpointStore.cursor(for: "notes") == nil {
                try checkpointStore.advance(bucket: "notes", to: note.itemKey, initialFloor: initialFloor ?? note.itemKey)
            } else {
                try checkpointStore.sinkFloor(bucket: "notes", to: note.itemKey)
            }
            ingested += 1
            if ingested % LiveLocalSourcesCoordinator.checkpointBatchSize == 0 {
                try await onCheckpointAdvanced()
            }
        }

        if !backfill.isEmpty || cursor?.floor != nil {
            let remainingBelowFloor: Bool = {
                guard let currentFloor = checkpointStore.cursor(for: "notes")?.floor else { return false }
                return candidates.contains { $0.itemKey < currentFloor }
            }()
            if !remainingBelowFloor {
                try checkpointStore.collapseFloor(bucket: "notes")
            }
        }

        return ingested
    }

    private static func makeIngestedItem(_ note: NoteCandidate) -> LiveIngestedItem {
        let digest = LiveSourceSQLite.digest("\(note.identifier)\0\(note.title)\0\(note.body)")
        return LiveIngestedItem(
            id: "notes:\(note.identifier)",
            source: .notes,
            bucket: "notes",
            title: note.title,
            subtitle: note.folder.isEmpty ? "Apple Notes" : "Apple Notes · \(note.folder)",
            body: note.body,
            timestamp: note.modifiedDate,
            orderKey: note.createdOrder,
            contentDigest: digest
        )
    }

    static func loadCandidates(snapshotURL: URL) throws -> [NoteCandidate] {
        let reader = try LiveSourceSQLite.Reader(path: snapshotURL.path)
        let columns = reader.tableColumns("ZICCLOUDSYNCINGOBJECT")
        guard columns.contains("ZIDENTIFIER"), columns.contains("ZNOTEDATA") else {
            throw LiveLocalSourceError.queryFailed("Unsupported Apple Notes schema.")
        }

        let titleExpr = columns.contains("ZTITLE1") ? "o.ZTITLE1" : (columns.contains("ZTITLE") ? "o.ZTITLE" : "NULL")
        let createdExpr = columns.contains("ZCREATIONDATE3")
            ? "COALESCE(o.ZCREATIONDATE3, o.ZCREATIONDATE1, o.ZMODIFICATIONDATE1, 0)"
            : (columns.contains("ZCREATIONDATE1") ? "COALESCE(o.ZCREATIONDATE1, o.ZMODIFICATIONDATE1, 0)" : "COALESCE(o.ZMODIFICATIONDATE1, 0)")
        let modifiedExpr = columns.contains("ZMODIFICATIONDATE1") ? "COALESCE(o.ZMODIFICATIONDATE1, 0)" : createdExpr
        let protectedPred = columns.contains("ZISPASSWORDPROTECTED") ? "COALESCE(o.ZISPASSWORDPROTECTED, 0) != 1" : "1=1"
        let deletedPred = columns.contains("ZMARKEDFORDELETION") ? "COALESCE(o.ZMARKEDFORDELETION, 0) != 1" : "1=1"
        let hasFolder = columns.contains("ZFOLDER") && columns.contains("ZTITLE2")

        let sql: String
        if hasFolder {
            sql = """
                SELECT o.ZIDENTIFIER, \(titleExpr), f.ZTITLE2, \(createdExpr), \(modifiedExpr), d.ZDATA
                FROM ZICCLOUDSYNCINGOBJECT o
                JOIN ZICNOTEDATA d ON d.Z_PK = o.ZNOTEDATA
                LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = o.ZFOLDER
                WHERE o.ZIDENTIFIER IS NOT NULL
                  AND d.ZDATA IS NOT NULL
                  AND \(protectedPred)
                  AND \(deletedPred)
                ORDER BY \(modifiedExpr) DESC, o.ZIDENTIFIER DESC
                LIMIT \(maxNotesWindow)
                """
        } else {
            sql = """
                SELECT o.ZIDENTIFIER, \(titleExpr), NULL, \(createdExpr), \(modifiedExpr), d.ZDATA
                FROM ZICCLOUDSYNCINGOBJECT o
                JOIN ZICNOTEDATA d ON d.Z_PK = o.ZNOTEDATA
                WHERE o.ZIDENTIFIER IS NOT NULL
                  AND d.ZDATA IS NOT NULL
                  AND \(protectedPred)
                  AND \(deletedPred)
                ORDER BY \(modifiedExpr) DESC, o.ZIDENTIFIER DESC
                LIMIT \(maxNotesWindow)
                """
        }

        var results: [NoteCandidate] = []
        try reader.query(sql) { stmt in
            guard let id = LiveSourceSQLite.Reader.text(stmt, 0)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  let blob = LiveSourceSQLite.Reader.blob(stmt, 5) else { return }
            let rawTitle = LiveSourceSQLite.Reader.text(stmt, 1)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let folder = LiveSourceSQLite.Reader.text(stmt, 2)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if folder.caseInsensitiveCompare("Recently Deleted") == .orderedSame { return }

            guard let decodedBody = decodeNoteBody(blob) else { return }
            let cleanedBody = LiveMessageBodyDecoder.cleanText(decodedBody)
            guard !cleanedBody.isEmpty else { return }

            let created = LiveSourceSQLite.Reader.double(stmt, 3)
            let modified = LiveSourceSQLite.Reader.double(stmt, 4)
            let effectiveOrder = created != 0 ? created : modified
            let firstLine = cleanedBody.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Untitled Note"
            let title = rawTitle.isEmpty ? NativePersonalSources.bounded(firstLine, maximumBytes: 120) : rawTitle

            results.append(NoteCandidate(
                identifier: id,
                title: title,
                folder: folder,
                body: NativePersonalSources.bounded(cleanedBody, maximumBytes: 12_000),
                createdOrder: effectiveOrder,
                modifiedDate: LiveSourceSQLite.appleDate(modified != 0 ? modified : effectiveOrder)
            ))
        }
        return results
    }

    static func decodeNoteBody(_ blob: Data) -> String? {
        if let strict = try? NotesBodyDecoder.decode(blob) {
            return strict.value
        }
        let inflated = gunzipLenient(blob) ?? blob
        return extractProtobufFieldPath(inflated, path: [2, 3, 2])
    }

    private static func gunzipLenient(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        var offset = 10
        let flags = bytes[3]
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count - 8 else { return nil }
            let xlen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + xlen
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {
            while offset < bytes.count - 8, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { return nil }
        let payload = Data(bytes[offset..<(bytes.count - 8)])
        let dstSize = 65_536
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }
        return payload.withUnsafeBytes { rawBuffer -> Data? in
            guard let srcPtr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var stream = compression_stream(dst_ptr: dst, dst_size: dstSize, src_ptr: srcPtr, src_size: payload.count, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = srcPtr
            stream.src_size = payload.count
            var out = Data()
            while true {
                stream.dst_ptr = dst
                stream.dst_size = dstSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = dstSize - stream.dst_size
                if produced > 0 {
                    guard out.count + produced <= 2 * 1_024 * 1_024 else { return nil }
                    out.append(dst, count: produced)
                }
                if status == COMPRESSION_STATUS_END { return out }
                if status != COMPRESSION_STATUS_OK || produced == 0 { return out.isEmpty ? nil : out }
            }
        }
    }

    private static func extractProtobufFieldPath(_ data: Data, path: [UInt64]) -> String? {
        var current = data
        for wantedField in path {
            guard let next = firstLengthDelimitedField(wantedField, in: current) else { return nil }
            current = next
        }
        return String(data: current, encoding: .utf8)
    }

    private static func firstLengthDelimitedField(_ wanted: UInt64, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var offset = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            for shift in 0..<10 {
                guard offset < bytes.count else { return nil }
                let b = bytes[offset]
                offset += 1
                value |= UInt64(b & 0x7f) << (shift * 7)
                if b & 0x80 == 0 { return value }
            }
            return nil
        }
        while offset < bytes.count {
            guard let tag = readVarint() else { return nil }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            switch wireType {
            case 0:
                guard readVarint() != nil else { return nil }
            case 1:
                guard offset + 8 <= bytes.count else { return nil }
                offset += 8
            case 2:
                guard let len64 = readVarint(), let len = Int(exactly: len64), offset + len <= bytes.count else { return nil }
                let slice = Data(bytes[offset..<(offset + len)])
                offset += len
                if fieldNumber == wanted { return slice }
            case 5:
                guard offset + 4 <= bytes.count else { return nil }
                offset += 4
            default:
                return nil
            }
        }
        return nil
    }
}

// MARK: - 2. Live iMessage Reader (`~/Library/Messages/chat.db`)

nonisolated enum LiveIMessageReader {
    static func listChats(databaseURL: URL, addressBookRootURL: URL, limit: Int = 200) throws -> [LiveChatDescriptor] {
        let (copyURL, tempDir) = try LiveSourceSQLite.walSafeCopy(of: databaseURL.path, label: "Messages")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let names = LiveAddressBookResolver.loadMap(addressBookRoot: addressBookRootURL)
        let reader = try LiveSourceSQLite.Reader(path: copyURL.path)
        let chatCols = reader.tableColumns("chat")
        let filterPred = chatCols.contains("is_filtered") ? "COALESCE(c.is_filtered, 0) <= 1" : "1=1"
        let blackholePred = chatCols.contains("is_blackholed") ? "COALESCE(c.is_blackholed, 0) = 0" : "1=1"

        var participantsByChat: [Int64: [String]] = [:]
        try? reader.query("""
            SELECT chj.chat_id, h.id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            """) { stmt in
            let chatID = LiveSourceSQLite.Reader.int64(stmt, 0)
            guard let handle = LiveSourceSQLite.Reader.text(stmt, 1), !handle.isEmpty else { return }
            let resolved = LiveAddressBookResolver.resolve(handle, in: names) ?? handle
            participantsByChat[chatID, default: []].append(resolved)
        }

        var chats: [LiveChatDescriptor] = []
        try reader.query("""
            SELECT c.ROWID, c.guid, c.display_name, c.chat_identifier, c.style, COUNT(m.ROWID), MAX(m.date)
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE c.guid IS NOT NULL
              AND \(filterPred)
              AND \(blackholePred)
              AND COALESCE(m.associated_message_type, 0) = 0
              AND COALESCE(m.item_type, 0) = 0
            GROUP BY c.ROWID
            ORDER BY MAX(m.date) DESC
            LIMIT \(max(1, limit))
            """) { stmt in
            let rowID = LiveSourceSQLite.Reader.int64(stmt, 0)
            guard let guid = LiveSourceSQLite.Reader.text(stmt, 1), !guid.isEmpty else { return }
            let displayName = LiveSourceSQLite.Reader.text(stmt, 2)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let identifier = LiveSourceSQLite.Reader.text(stmt, 3)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? guid
            let style = LiveSourceSQLite.Reader.int64(stmt, 4)
            let count = Int(LiveSourceSQLite.Reader.int64(stmt, 5))
            let maxDateRaw = LiveSourceSQLite.Reader.double(stmt, 6)

            let participants = participantsByChat[rowID] ?? []
            let resolvedIdentifier = LiveAddressBookResolver.resolve(identifier, in: names) ?? identifier
            let title: String
            if !displayName.isEmpty {
                title = displayName
            } else if !participants.isEmpty {
                title = participants.prefix(3).joined(separator: ", ")
            } else {
                title = resolvedIdentifier
            }
            let isGroup = style == 43 || participants.count > 1
            chats.append(LiveChatDescriptor(
                id: guid,
                source: .imessage,
                title: title,
                participantSummary: participants.isEmpty ? identifier : participants.joined(separator: ", "),
                isGroup: isGroup,
                messageCount: count,
                lastMessageAt: maxDateRaw > 0 ? LiveSourceSQLite.appleDate(maxDateRaw) : nil
            ))
        }
        return chats
    }

    static func readIncremental(
        databaseURL: URL,
        addressBookRootURL: URL,
        selectedChatGUIDs: Set<String>?,
        checkpointStore: LiveSourceCheckpointStore,
        now: Date = Date(),
        maxWindowsPerPass: Int = 100,
        onItem: (LiveIngestedItem) async throws -> Void,
        onCheckpointAdvanced: () async throws -> Void = {}
    ) async throws -> Int {
        let (copyURL, tempDir) = try LiveSourceSQLite.walSafeCopy(of: databaseURL.path, label: "Messages")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let names = LiveAddressBookResolver.loadMap(addressBookRoot: addressBookRootURL)
        let reader = try LiveSourceSQLite.Reader(path: copyURL.path)
        let chatCols = reader.tableColumns("chat")
        let filterPred = chatCols.contains("is_filtered") ? "COALESCE(c.is_filtered, 0) <= 1" : "1=1"
        let blackholePred = chatCols.contains("is_blackholed") ? "COALESCE(c.is_blackholed, 0) = 0" : "1=1"
        let cutoffAppleSeconds = now.addingTimeInterval(-LiveChatWindowing.lookbackSeconds).timeIntervalSince1970 - LiveSourceSQLite.appleEpochOffset
        let cutoffNano = cutoffAppleSeconds * 1_000_000_000

        var chatMeta: [Int64: (guid: String, title: String)] = [:]
        var participantsByChat: [Int64: [String]] = [:]
        try? reader.query("""
            SELECT chj.chat_id, h.id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            """) { stmt in
            let cid = LiveSourceSQLite.Reader.int64(stmt, 0)
            guard let raw = LiveSourceSQLite.Reader.text(stmt, 1), !raw.isEmpty else { return }
            participantsByChat[cid, default: []].append(LiveAddressBookResolver.resolve(raw, in: names) ?? raw)
        }

        try reader.query("""
            SELECT c.ROWID, c.guid, c.display_name, c.chat_identifier
            FROM chat c
            WHERE c.guid IS NOT NULL AND \(filterPred) AND \(blackholePred)
            """) { stmt in
            let cid = LiveSourceSQLite.Reader.int64(stmt, 0)
            guard let guid = LiveSourceSQLite.Reader.text(stmt, 1), !guid.isEmpty else { return }
            if let selectedChatGUIDs, !selectedChatGUIDs.isEmpty, !selectedChatGUIDs.contains(guid) {
                return
            }
            let display = LiveSourceSQLite.Reader.text(stmt, 2)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ident = LiveSourceSQLite.Reader.text(stmt, 3)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? guid
            let participants = participantsByChat[cid] ?? []
            let title = !display.isEmpty ? display : (!participants.isEmpty ? participants.prefix(3).joined(separator: ", ") : (LiveAddressBookResolver.resolve(ident, in: names) ?? ident))
            chatMeta[cid] = (guid, title)
        }

        guard !chatMeta.isEmpty else { return 0 }
        let sortedChatIDs = chatMeta.keys.sorted()

        var messagesByChat: [Int64: [LiveChatWindowing.MessageEntry]] = [:]
        let chunkSize = 400
        for chunkStart in stride(from: 0, to: sortedChatIDs.count, by: chunkSize) {
            let chunk = sortedChatIDs[chunkStart..<min(chunkStart + chunkSize, sortedChatIDs.count)]
            let chatIDList = chunk.map(String.init).joined(separator: ",")
            try reader.query("""
                SELECT cmj.chat_id, m.ROWID, m.guid, m.date, m.is_from_me, h.id, m.text, m.attributedBody
                FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE cmj.chat_id IN (\(chatIDList))
                  AND COALESCE(m.associated_message_type, 0) = 0
                  AND COALESCE(m.item_type, 0) = 0
                  AND (
                        (ABS(m.date) > 100000000000 AND m.date >= \(Int64(cutoffNano)))
                     OR (ABS(m.date) <= 100000000000 AND m.date >= \(cutoffAppleSeconds))
                  )
                ORDER BY m.date ASC, m.ROWID ASC
                LIMIT \(LiveChatWindowing.maxMessagesPerQuery)
                """) { stmt in
                let cid = LiveSourceSQLite.Reader.int64(stmt, 0)
                let rowID = LiveSourceSQLite.Reader.int64(stmt, 1)
                let msgGUID = LiveSourceSQLite.Reader.text(stmt, 2) ?? String(rowID)
                let rawDate = LiveSourceSQLite.Reader.double(stmt, 3)
                let isFromMe = LiveSourceSQLite.Reader.int64(stmt, 4) != 0
                let handle = LiveSourceSQLite.Reader.text(stmt, 5) ?? ""
                let plain = LiveSourceSQLite.Reader.text(stmt, 6)
                let blob = LiveSourceSQLite.Reader.blob(stmt, 7, maxBytes: 256 * 1_024)

                guard let decoded = LiveMessageBodyDecoder.decode(plainText: plain, attributedBody: blob) else { return }
                let date = LiveSourceSQLite.appleDate(rawDate)
                let orderSeconds = date.timeIntervalSince1970 - LiveSourceSQLite.appleEpochOffset
                let sender = isFromMe ? "Me" : (LiveAddressBookResolver.resolve(handle, in: names) ?? (handle.isEmpty ? "Participant" : handle))

                messagesByChat[cid, default: []].append(LiveChatWindowing.MessageEntry(
                    id: "imessage:\(msgGUID)",
                    orderKey: orderSeconds,
                    timestamp: date,
                    sender: sender,
                    isFromMe: isFromMe,
                    text: decoded
                ))
            }
        }

        var ingested = 0
        for cid in messagesByChat.keys.sorted() {
            guard let meta = chatMeta[cid], let entries = messagesByChat[cid], !entries.isEmpty else { continue }
            let bucket = "imessage:\(meta.guid)"
            let windows = LiveChatWindowing.buildWindows(chatID: meta.guid, chatTitle: meta.title, bucket: bucket, messages: entries)
            let cursor = checkpointStore.cursor(for: bucket)
            let (forward, backfill, initialFloor) = LiveChatWindowing.partition(windows: windows, cursor: cursor)

            for win in forward {
                try Task.checkCancellation()
                guard ingested < maxWindowsPerPass else { return ingested }
                let item = makeWindowItem(source: .imessage, window: win)
                try await onItem(item)
                try checkpointStore.advance(bucket: bucket, to: win.lastKey)
                ingested += 1
                if ingested % LiveLocalSourcesCoordinator.checkpointBatchSize == 0 {
                    try await onCheckpointAdvanced()
                }
            }

            for win in backfill {
                try Task.checkCancellation()
                guard ingested < maxWindowsPerPass else { return ingested }
                let item = makeWindowItem(source: .imessage, window: win)
                try await onItem(item)
                if checkpointStore.cursor(for: bucket) == nil {
                    try checkpointStore.advance(bucket: bucket, to: win.lastKey, initialFloor: initialFloor ?? win.lastKey)
                } else {
                    try checkpointStore.sinkFloor(bucket: bucket, to: win.lastKey)
                }
                ingested += 1
                if ingested % LiveLocalSourcesCoordinator.checkpointBatchSize == 0 {
                    try await onCheckpointAdvanced()
                }
            }

            if let currentFloor = checkpointStore.cursor(for: bucket)?.floor {
                let moreBelow = windows.contains { $0.lastKey < currentFloor }
                if !moreBelow {
                    try checkpointStore.collapseFloor(bucket: bucket)
                }
            }
        }
        return ingested
    }

    static func collectWritingSamples(databaseURL: URL, addressBookRootURL: URL, selectedChatGUIDs: Set<String>?, peopleLimit: Int = 6, messagesPerPerson: Int = 5) throws -> [LiveWritingSample] {
        let (copyURL, tempDir) = try LiveSourceSQLite.walSafeCopy(of: databaseURL.path, label: "Messages")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let names = LiveAddressBookResolver.loadMap(addressBookRoot: addressBookRootURL)
        let reader = try LiveSourceSQLite.Reader(path: copyURL.path)

        struct ContactBucket {
            var chatIDs: [Int64]
            var lastDate: Double
            let recipient: String
        }
        var contacts: [String: ContactBucket] = [:]
        try reader.query("""
            SELECT c.ROWID, c.guid, c.chat_identifier, MAX(m.date)
            FROM chat c
            JOIN chat_message_join j ON j.chat_id = c.ROWID
            JOIN message m ON m.ROWID = j.message_id
            WHERE c.style = 45
              AND COALESCE(m.associated_message_type, 0) = 0
              AND COALESCE(m.item_type, 0) = 0
            GROUP BY c.ROWID
            """) { stmt in
            let cid = LiveSourceSQLite.Reader.int64(stmt, 0)
            guard let guid = LiveSourceSQLite.Reader.text(stmt, 1),
                  let ident = LiveSourceSQLite.Reader.text(stmt, 2), !ident.isEmpty else { return }
            if let selectedChatGUIDs, !selectedChatGUIDs.isEmpty, !selectedChatGUIDs.contains(guid) { return }
            let key = ident.lowercased()
            var entry = contacts[key] ?? ContactBucket(chatIDs: [], lastDate: 0, recipient: LiveAddressBookResolver.resolve(ident, in: names) ?? ident)
            entry.chatIDs.append(cid)
            entry.lastDate = max(entry.lastDate, LiveSourceSQLite.Reader.double(stmt, 3))
            contacts[key] = entry
        }

        var output: [LiveWritingSample] = []
        var peopleCount = 0
        for (_, contact) in contacts.sorted(by: { $0.value.lastDate > $1.value.lastDate }) {
            let ids = contact.chatIDs.sorted().map(String.init).joined(separator: ",")
            var samplesForPerson: [LiveWritingSample] = []
            try reader.query("""
                SELECT DISTINCT m.ROWID, m.date, m.text, m.attributedBody
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id IN (\(ids))
                  AND m.is_from_me = 1
                  AND COALESCE(m.associated_message_type, 0) = 0
                  AND COALESCE(m.item_type, 0) = 0
                ORDER BY m.date DESC, m.ROWID DESC
                LIMIT \(messagesPerPerson * 3)
                """) { stmt in
                guard samplesForPerson.count < messagesPerPerson else { return }
                let rawDate = LiveSourceSQLite.Reader.double(stmt, 1)
                let plain = LiveSourceSQLite.Reader.text(stmt, 2)
                let blob = LiveSourceSQLite.Reader.blob(stmt, 3, maxBytes: 256 * 1_024)
                guard let body = LiveMessageBodyDecoder.decode(plainText: plain, attributedBody: blob) else { return }
                samplesForPerson.append(LiveWritingSample(
                    source: .imessage,
                    recipient: contact.recipient,
                    subject: nil,
                    text: body,
                    sentAt: rawDate > 0 ? LiveSourceSQLite.appleDate(rawDate) : nil
                ))
            }
            guard !samplesForPerson.isEmpty else { continue }
            output.append(contentsOf: samplesForPerson)
            peopleCount += 1
            if peopleCount >= peopleLimit { break }
        }
        return output
    }
}

private nonisolated func makeWindowItem(source: LiveLocalSourceKind, window: LiveChatWindowing.Window) -> LiveIngestedItem {
    let body = window.combinedText
    let last = window.entries.last!
    let digest = LiveSourceSQLite.digest("\(window.bucket)\0\(last.id)\0\(body)")
    return LiveIngestedItem(
        id: "\(window.bucket)#\(last.id)",
        source: source,
        bucket: window.bucket,
        title: window.chatTitle,
        subtitle: "\(source.title) · \(window.entries.count) messages",
        body: body,
        timestamp: last.timestamp,
        orderKey: last.orderKey,
        contentDigest: digest
    )
}

// MARK: - 3. Live WhatsApp Reader (`ChatStorage.sqlite`)

nonisolated enum LiveWhatsAppReader {
    @MainActor
    static func isInstalled(databaseURL: URL) -> Bool {
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            return true
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") != nil
    }

    static func cleanName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("@lid") || trimmed.hasSuffix("@s.whatsapp.net") || trimmed.hasSuffix("@g.us") {
            return nil
        }
        // Reject opaque base64/LID-like tokens without spaces that mix digits/symbols suspiciously
        if !trimmed.contains(" "), trimmed.count >= 20,
           trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" || $0 == "_" || $0 == "-" }) {
            return nil
        }
        return trimmed
    }

    static func handle(from jid: String) -> String {
        if let at = jid.firstIndex(of: "@") {
            let prefix = String(jid[..<at])
            if prefix.allSatisfy(\.isNumber), prefix.count >= 7 {
                return "+" + prefix
            }
            return prefix
        }
        return jid
    }

    static func listChats(databaseURL: URL, limit: Int = 200) throws -> [LiveChatDescriptor] {
        let (copyURL, tempDir) = try LiveSourceSQLite.walSafeCopy(of: databaseURL.path, label: "WhatsApp")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let reader = try LiveSourceSQLite.Reader(path: copyURL.path)
        let sessionCols = reader.tableColumns("ZWACHATSESSION")
        let hasParent = sessionCols.contains("ZPARENTCHAT")

        let communityExclusion = hasParent
            ? """
              AND COALESCE(s.ZSESSIONTYPE, 0) IN (0, 1)
              AND (s.ZPARENTCHAT IS NULL OR s.ZPARENTCHAT NOT IN (
                  SELECT p.Z_PK FROM ZWACHATSESSION p WHERE p.ZSESSIONTYPE = 4 AND p.Z_PK IS NOT NULL
              ))
              """
            : "AND COALESCE(s.ZSESSIONTYPE, 0) IN (0, 1)"

        var chats: [LiveChatDescriptor] = []
        try reader.query("""
            SELECT s.Z_PK, s.ZCONTACTJID, s.ZPARTNERNAME, COALESCE(s.ZSESSIONTYPE, 0), COUNT(m.Z_PK), MAX(m.ZMESSAGEDATE)
            FROM ZWACHATSESSION s
            JOIN ZWAMESSAGE m ON m.ZCHATSESSION = s.Z_PK
            WHERE s.ZCONTACTJID IS NOT NULL
              AND (s.ZCONTACTJID LIKE '%@s.whatsapp.net' OR s.ZCONTACTJID LIKE '%@lid' OR s.ZCONTACTJID LIKE '%@g.us')
              \(communityExclusion)
            GROUP BY s.Z_PK
            ORDER BY MAX(m.ZMESSAGEDATE) DESC
            LIMIT \(max(1, limit))
            """) { stmt in
            guard let jid = LiveSourceSQLite.Reader.text(stmt, 1), !jid.isEmpty else { return }
            let partner = cleanName(LiveSourceSQLite.Reader.text(stmt, 2))
            let sessionType = LiveSourceSQLite.Reader.int64(stmt, 3)
            let count = Int(LiveSourceSQLite.Reader.int64(stmt, 4))
            let lastRaw = LiveSourceSQLite.Reader.double(stmt, 5)
            let isGroup = sessionType == 1 || jid.hasSuffix("@g.us")
            let fallback = jid.hasSuffix("@lid") ? "WhatsApp Contact" : handle(from: jid)

            chats.append(LiveChatDescriptor(
                id: jid,
                source: .whatsapp,
                title: partner ?? fallback,
                participantSummary: fallback,
                isGroup: isGroup,
                messageCount: count,
                lastMessageAt: lastRaw > 0 ? LiveSourceSQLite.appleDate(lastRaw) : nil
            ))
        }
        return chats
    }

    static func readIncremental(
        databaseURL: URL,
        selectedChatJIDs: Set<String>?,
        checkpointStore: LiveSourceCheckpointStore,
        now: Date = Date(),
        maxWindowsPerPass: Int = 100,
        onItem: (LiveIngestedItem) async throws -> Void,
        onCheckpointAdvanced: () async throws -> Void = {}
    ) async throws -> Int {
        let (copyURL, tempDir) = try LiveSourceSQLite.walSafeCopy(of: databaseURL.path, label: "WhatsApp")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reader = try LiveSourceSQLite.Reader(path: copyURL.path)
        let sessionCols = reader.tableColumns("ZWACHATSESSION")
        let hasParent = sessionCols.contains("ZPARENTCHAT")
        let communityExclusion = hasParent
            ? """
              AND COALESCE(s.ZSESSIONTYPE, 0) IN (0, 1)
              AND (s.ZPARENTCHAT IS NULL OR s.ZPARENTCHAT NOT IN (
                  SELECT p.Z_PK FROM ZWACHATSESSION p WHERE p.ZSESSIONTYPE = 4 AND p.Z_PK IS NOT NULL
              ))
              """
            : "AND COALESCE(s.ZSESSIONTYPE, 0) IN (0, 1)"

        var pushNames: [String: String] = [:]
        if !reader.tableColumns("ZWAPROFILEPUSHNAME").isEmpty {
            try? reader.query("SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME WHERE ZJID IS NOT NULL AND ZPUSHNAME IS NOT NULL") { stmt in
                if let jid = LiveSourceSQLite.Reader.text(stmt, 0),
                   let cleaned = cleanName(LiveSourceSQLite.Reader.text(stmt, 1)) {
                    pushNames[jid] = cleaned
                }
            }
        }

        var groupMembers: [Int64: String] = [:]
        if !reader.tableColumns("ZWAGROUPMEMBER").isEmpty {
            try? reader.query("SELECT Z_PK, ZMEMBERJID, ZCONTACTNAME FROM ZWAGROUPMEMBER") { stmt in
                let pk = LiveSourceSQLite.Reader.int64(stmt, 0)
                let memberJID = LiveSourceSQLite.Reader.text(stmt, 1) ?? ""
                let contactName = cleanName(LiveSourceSQLite.Reader.text(stmt, 2))
                let resolved = contactName ?? pushNames[memberJID] ?? (memberJID.isEmpty ? nil : handle(from: memberJID))
                if let resolved {
                    groupMembers[pk] = resolved
                }
            }
        }

        var sessions: [Int64: (jid: String, title: String)] = [:]
        try reader.query("""
            SELECT s.Z_PK, s.ZCONTACTJID, s.ZPARTNERNAME
            FROM ZWACHATSESSION s
            WHERE s.ZCONTACTJID IS NOT NULL
              AND (s.ZCONTACTJID LIKE '%@s.whatsapp.net' OR s.ZCONTACTJID LIKE '%@lid' OR s.ZCONTACTJID LIKE '%@g.us')
              \(communityExclusion)
            """) { stmt in
            let pk = LiveSourceSQLite.Reader.int64(stmt, 0)
            guard let jid = LiveSourceSQLite.Reader.text(stmt, 1), !jid.isEmpty else { return }
            if let selectedChatJIDs, !selectedChatJIDs.isEmpty, !selectedChatJIDs.contains(jid) { return }
            let partner = cleanName(LiveSourceSQLite.Reader.text(stmt, 2)) ?? pushNames[jid]
            let fallback = jid.hasSuffix("@lid") ? "WhatsApp Contact" : handle(from: jid)
            sessions[pk] = (jid, partner ?? fallback)
        }

        guard !sessions.isEmpty else { return 0 }
        let sortedSessionIDs = sessions.keys.sorted()
        let cutoffApple = now.addingTimeInterval(-LiveChatWindowing.lookbackSeconds).timeIntervalSince1970 - LiveSourceSQLite.appleEpochOffset
        let msgCols = reader.tableColumns("ZWAMESSAGE")
        let memberCol = msgCols.contains("ZGROUPMEMBER") ? "m.ZGROUPMEMBER" : "NULL"
        let stanzaCol = msgCols.contains("ZSTANZAID") ? "m.ZSTANZAID" : "NULL"

        var messagesBySession: [Int64: [LiveChatWindowing.MessageEntry]] = [:]
        let chunkSize = 400
        for chunkStart in stride(from: 0, to: sortedSessionIDs.count, by: chunkSize) {
            let chunk = sortedSessionIDs[chunkStart..<min(chunkStart + chunkSize, sortedSessionIDs.count)]
            let sessionList = chunk.map(String.init).joined(separator: ",")
            try reader.query("""
                SELECT m.ZCHATSESSION, m.Z_PK, \(stanzaCol), m.ZMESSAGEDATE, m.ZISFROMME, \(memberCol), m.ZFROMJID, m.ZTEXT
                FROM ZWAMESSAGE m
                WHERE m.ZCHATSESSION IN (\(sessionList))
                  AND COALESCE(m.ZMESSAGETYPE, 0) = 0
                  AND m.ZTEXT IS NOT NULL
                  AND m.ZMESSAGEDATE >= \(cutoffApple)
                ORDER BY m.ZMESSAGEDATE ASC, m.Z_PK ASC
                LIMIT \(LiveChatWindowing.maxMessagesPerQuery)
                """) { stmt in
                let sid = LiveSourceSQLite.Reader.int64(stmt, 0)
                let pk = LiveSourceSQLite.Reader.int64(stmt, 1)
                let stanza = LiveSourceSQLite.Reader.text(stmt, 2) ?? String(pk)
                let rawDate = LiveSourceSQLite.Reader.double(stmt, 3)
                let isFromMe = LiveSourceSQLite.Reader.int64(stmt, 4) != 0
                let memberPK = LiveSourceSQLite.Reader.int64(stmt, 5)
                let fromJID = LiveSourceSQLite.Reader.text(stmt, 6) ?? ""
                guard let rawText = LiveSourceSQLite.Reader.text(stmt, 7) else { return }
                let cleaned = LiveMessageBodyDecoder.cleanText(rawText)
                guard !cleaned.isEmpty else { return }

                let sender: String
                if isFromMe {
                    sender = "Me"
                } else if let member = groupMembers[memberPK] {
                    sender = member
                } else if let pushed = pushNames[fromJID] {
                    sender = pushed
                } else if let meta = sessions[sid], !meta.jid.hasSuffix("@g.us") {
                    sender = meta.title
                } else if !fromJID.isEmpty {
                    sender = fromJID.hasSuffix("@lid") ? "Participant" : handle(from: fromJID)
                } else {
                    sender = "Participant"
                }

                messagesBySession[sid, default: []].append(LiveChatWindowing.MessageEntry(
                    id: "whatsapp:\(stanza)",
                    orderKey: rawDate,
                    timestamp: LiveSourceSQLite.appleDate(rawDate),
                    sender: sender,
                    isFromMe: isFromMe,
                    text: cleaned
                ))
            }
        }

        var ingested = 0
        for sid in messagesBySession.keys.sorted() {
            guard let meta = sessions[sid], let entries = messagesBySession[sid], !entries.isEmpty else { continue }
            let bucket = "whatsapp:\(meta.jid)"
            let windows = LiveChatWindowing.buildWindows(chatID: meta.jid, chatTitle: meta.title, bucket: bucket, messages: entries)
            let cursor = checkpointStore.cursor(for: bucket)
            let (forward, backfill, initialFloor) = LiveChatWindowing.partition(windows: windows, cursor: cursor)

            for win in forward {
                try Task.checkCancellation()
                guard ingested < maxWindowsPerPass else { return ingested }
                try await onItem(makeWindowItem(source: .whatsapp, window: win))
                try checkpointStore.advance(bucket: bucket, to: win.lastKey)
                ingested += 1
                if ingested % LiveLocalSourcesCoordinator.checkpointBatchSize == 0 {
                    try await onCheckpointAdvanced()
                }
            }

            for win in backfill {
                try Task.checkCancellation()
                guard ingested < maxWindowsPerPass else { return ingested }
                try await onItem(makeWindowItem(source: .whatsapp, window: win))
                if checkpointStore.cursor(for: bucket) == nil {
                    try checkpointStore.advance(bucket: bucket, to: win.lastKey, initialFloor: initialFloor ?? win.lastKey)
                } else {
                    try checkpointStore.sinkFloor(bucket: bucket, to: win.lastKey)
                }
                ingested += 1
                if ingested % LiveLocalSourcesCoordinator.checkpointBatchSize == 0 {
                    try await onCheckpointAdvanced()
                }
            }

            if let currentFloor = checkpointStore.cursor(for: bucket)?.floor {
                if !windows.contains(where: { $0.lastKey < currentFloor }) {
                    try checkpointStore.collapseFloor(bucket: bucket)
                }
            }
        }
        return ingested
    }

    static func collectWritingSamples(databaseURL: URL, selectedChatJIDs: Set<String>?, peopleLimit: Int = 6, messagesPerPerson: Int = 5) throws -> [LiveWritingSample] {
        let (copyURL, tempDir) = try LiveSourceSQLite.walSafeCopy(of: databaseURL.path, label: "WhatsApp")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let reader = try LiveSourceSQLite.Reader(path: copyURL.path)

        struct SessionContact {
            var sessionPKs: [Int64]
            var lastDate: Double
            let name: String
        }
        var contacts: [String: SessionContact] = [:]
        try reader.query("""
            SELECT s.Z_PK, s.ZCONTACTJID, MAX(m.ZMESSAGEDATE), s.ZPARTNERNAME
            FROM ZWACHATSESSION s
            JOIN ZWAMESSAGE m ON m.ZCHATSESSION = s.Z_PK
            WHERE COALESCE(s.ZSESSIONTYPE, 0) = 0 AND s.ZCONTACTJID IS NOT NULL
            GROUP BY s.Z_PK
            """) { stmt in
            let pk = LiveSourceSQLite.Reader.int64(stmt, 0)
            guard let jid = LiveSourceSQLite.Reader.text(stmt, 1),
                  jid.hasSuffix("@s.whatsapp.net") || jid.hasSuffix("@lid") else { return }
            if let selectedChatJIDs, !selectedChatJIDs.isEmpty, !selectedChatJIDs.contains(jid) { return }
            let name = cleanName(LiveSourceSQLite.Reader.text(stmt, 3)) ?? (jid.hasSuffix("@lid") ? "Unknown contact" : handle(from: jid))
            var entry = contacts[jid] ?? SessionContact(sessionPKs: [], lastDate: 0, name: name)
            entry.sessionPKs.append(pk)
            entry.lastDate = max(entry.lastDate, LiveSourceSQLite.Reader.double(stmt, 2))
            contacts[jid] = entry
        }

        var output: [LiveWritingSample] = []
        var people = 0
        for (_, contact) in contacts.sorted(by: { $0.value.lastDate > $1.value.lastDate }) {
            let ids = contact.sessionPKs.sorted().map(String.init).joined(separator: ",")
            var batch: [LiveWritingSample] = []
            try reader.query("""
                SELECT ZTEXT, ZMESSAGEDATE FROM ZWAMESSAGE
                WHERE ZCHATSESSION IN (\(ids))
                  AND ZISFROMME = 1
                  AND COALESCE(ZMESSAGETYPE, 0) = 0
                  AND ZTEXT IS NOT NULL
                ORDER BY ZMESSAGEDATE DESC, Z_PK DESC
                LIMIT \(messagesPerPerson)
                """) { stmt in
                guard let text = LiveSourceSQLite.Reader.text(stmt, 0) else { return }
                let cleaned = LiveMessageBodyDecoder.cleanText(text)
                guard !cleaned.isEmpty else { return }
                let rawDate = LiveSourceSQLite.Reader.double(stmt, 1)
                batch.append(LiveWritingSample(
                    source: .whatsapp,
                    recipient: contact.name,
                    subject: nil,
                    text: cleaned,
                    sentAt: rawDate > 0 ? LiveSourceSQLite.appleDate(rawDate) : nil
                ))
            }
            guard !batch.isEmpty else { continue }
            output.append(contentsOf: batch)
            people += 1
            if people >= peopleLimit { break }
        }
        return output
    }
}

// MARK: - 4. Live Apple Mail Reader (`Envelope Index` + `.emlx`, SRC-13/14, TRI-05/06)

nonisolated enum LiveAppleMailReader {
    static let maxEmlxBytes = 10 * 1_024 * 1_024
    static let maxIndexedEmlxFiles = 150_000
    static let maxBodyTextBytes = 12_000

    struct ParsedEmlx: Sendable, Equatable {
        let messageIDHeader: String?
        let from: String
        let to: String
        let subject: String
        let listUnsubscribe: Bool
        let listID: Bool
        let precedenceBulk: Bool
        let rawHeaders: [String: String]
        let bodyText: String
    }

    static func locateVersionDirectory(mailRootURL: URL) throws -> URL {
        let fm = FileManager.default
        let probeFD = mailRootURL.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        if probeFD < 0 {
            let code = errno
            if code == EPERM || code == EACCES {
                throw LiveLocalSourceError.fullDiskAccessRequired("Apple Mail")
            }
            throw LiveLocalSourceError.sourceDatabaseMissing("Apple Mail")
        }
        Darwin.close(probeFD)

        // Allow direct pointing at a V* directory in tests
        if fm.fileExists(atPath: mailRootURL.appending(path: "MailData/Envelope Index").path) {
            return mailRootURL
        }

        let entries = (try? fm.contentsOfDirectory(at: mailRootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let versions = entries.compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("V"), let number = Int(name.dropFirst()),
                  fm.fileExists(atPath: url.appending(path: "MailData/Envelope Index").path) else { return nil }
            return (number, url)
        }.sorted { $0.0 > $1.0 }

        guard let newest = versions.first?.1 else {
            throw LiveLocalSourceError.sourceDatabaseMissing("Apple Mail Envelope Index")
        }
        return newest
    }

    static func listAccounts(mailRootURL: URL) throws -> [LiveMailAccountDescriptor] {
        let versionDir = try locateVersionDirectory(mailRootURL: mailRootURL)
        let indexPath = versionDir.appending(path: "MailData/Envelope Index").path
        let (backupURL, tempDir) = try LiveSourceSQLite.walSafeCopy(of: indexPath, label: "Apple Mail")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reader = try LiveSourceSQLite.Reader(path: backupURL.path)
        var countsByAccount: [String: Int] = [:]
        try reader.query("SELECT url FROM mailboxes WHERE url IS NOT NULL") { stmt in
            guard let urlString = LiveSourceSQLite.Reader.text(stmt, 0),
                  let components = URLComponents(string: urlString),
                  let host = components.host, !host.isEmpty else { return }
            countsByAccount[host, default: 0] += 1
        }
        return countsByAccount.keys.sorted().map { host in
            LiveMailAccountDescriptor(id: host, displayName: host, mailboxCount: countsByAccount[host] ?? 0)
        }
    }

    static func readIncremental(
        mailRootURL: URL,
        selectedAccountIDs: Set<String>?,
        checkpointStore: LiveSourceCheckpointStore,
        now: Date = Date(),
        maxItemsPerPass: Int = 50,
        onItem: (LiveIngestedItem) async throws -> Void,
        onCheckpointAdvanced: () async throws -> Void = {}
    ) async throws -> Int {
        let versionDir = try locateVersionDirectory(mailRootURL: mailRootURL)
        let indexPath = versionDir.appending(path: "MailData/Envelope Index").path
        let (backupURL, tempDir) = try LiveSourceSQLite.walSafeCopy(of: indexPath, label: "Apple Mail")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reader = try LiveSourceSQLite.Reader(path: backupURL.path)
        let generation = readIndexGeneration(reader: reader, fallbackPath: indexPath)
        let accountScopeKey: String
        if let selectedAccountIDs, !selectedAccountIDs.isEmpty {
            accountScopeKey = "accounts:" + selectedAccountIDs.sorted().joined(separator: ",")
        } else {
            accountScopeKey = "all"
        }

        let candidateRows = try loadEligibleMailRows(
            reader: reader,
            selectedAccountIDs: selectedAccountIDs
        )
        guard !candidateRows.isEmpty else { return 0 }

        var checkpoint = checkpointStore.mailCheckpoint(for: accountScopeKey)
            ?? MailIngestion.Checkpoint(generation: generation, top: candidateRows.map { $0.mailRow.id }.max() ?? 0)
        let recoveringGeneration = checkpoint.generation != generation

        let workItems = checkpoint.prepare(generation: generation, rows: candidateRows.map(\.mailRow), now: now, limit: maxItemsPerPass)
        guard !workItems.isEmpty else { return 0 }

        let targetRowIDs = Set(workItems.map { $0.row.id })
        let emlxIndex = indexEmlxFiles(in: versionDir, matchingRowIDs: targetRowIDs)
        let rowsByNumber = Dictionary(candidateRows.map { ($0.mailRow.id, $0) }, uniquingKeysWith: { first, _ in first })

        var ingested = 0
        var checkpointMutations = 0
        for work in workItems {
            try Task.checkCancellation()
            let row = work.row
            guard let fullRow = rowsByNumber[row.id] else { continue }
            let itemID = LiveSourceSQLite.digest("\(checkpoint.salt)\0\(row.messageID)")

            // Generation-recovery fast path: if content was already ingested under same stable Message-ID salt, advance without duplicating!
            if recoveringGeneration,
               let existingReceipt = checkpointStore.mailReceipt(for: itemID),
               existingReceipt.version == LiveSourceCheckpointStore.MailReceipt.currentVersion {
                checkpoint.recordResult(for: work, bodyAvailable: true, now: now)
                try checkpointStore.commitMailCheckpoint(checkpoint, accountKey: accountScopeKey)
                checkpointMutations += 1
                if checkpointMutations % LiveLocalSourcesCoordinator.checkpointBatchSize == 0 {
                    try await onCheckpointAdvanced()
                }
                continue
            }

            guard let emlxURL = emlxIndex[row.id],
                  let parsed = parseEmlxFile(at: emlxURL, expectedMessageID: fullRow.messageIDHeader) else {
                checkpoint.recordResult(for: work, bodyAvailable: false, now: now)
                try checkpointStore.commitMailCheckpoint(checkpoint, accountKey: accountScopeKey)
                checkpointMutations += 1
                if checkpointMutations % LiveLocalSourcesCoordinator.checkpointBatchSize == 0 {
                    try await onCheckpointAdvanced()
                }
                continue
            }

            // Secondary header-level bulk/promotional guard (`SRC-14`)
            if !fullRow.isSentMailbox, (parsed.listUnsubscribe || parsed.listID || parsed.precedenceBulk || MailIngestion.MIMEFilter.isExcluded(headers: parsed.rawHeaders)) {
                checkpoint.recordResult(for: work, bodyAvailable: true, now: now)
                try checkpointStore.commitMailCheckpoint(checkpoint, accountKey: accountScopeKey)
                checkpointMutations += 1
                if checkpointMutations % LiveLocalSourcesCoordinator.checkpointBatchSize == 0 {
                    try await onCheckpointAdvanced()
                }
                continue
            }

            let cleanedBody = LiveMessageBodyDecoder.cleanText(parsed.bodyText)
            guard !cleanedBody.isEmpty else {
                checkpoint.recordResult(for: work, bodyAvailable: true, now: now)
                try checkpointStore.commitMailCheckpoint(checkpoint, accountKey: accountScopeKey)
                checkpointMutations += 1
                if checkpointMutations % LiveLocalSourcesCoordinator.checkpointBatchSize == 0 {
                    try await onCheckpointAdvanced()
                }
                continue
            }

            let subject = parsed.subject.isEmpty ? fullRow.subject : parsed.subject
            let senderLine = parsed.from.isEmpty ? fullRow.sender : parsed.from
            let subtitle = fullRow.isSentMailbox
                ? "Apple Mail · Sent to \(parsed.to.isEmpty ? "recipient" : parsed.to)"
                : "Apple Mail · From \(senderLine)"
            let digest = LiveSourceSQLite.digest("\(itemID)\0\(subject)\0\(cleanedBody)")

            let item = LiveIngestedItem(
                id: "mail:\(itemID)",
                source: .appleMail,
                bucket: "apple_mail:\(accountScopeKey)",
                title: subject.isEmpty ? "(No Subject)" : subject,
                subtitle: subtitle,
                body: NativePersonalSources.bounded(cleanedBody, maximumBytes: maxBodyTextBytes),
                timestamp: row.date,
                orderKey: row.date.timeIntervalSince1970,
                contentDigest: digest
            )

            try await onItem(item)
            checkpoint.recordResult(for: work, bodyAvailable: true, now: now)
            try checkpointStore.commitMailCheckpoint(
                checkpoint,
                accountKey: accountScopeKey,
                receipt: (id: itemID, digest: digest, at: now)
            )
            ingested += 1
            checkpointMutations += 1
            if ingested % LiveLocalSourcesCoordinator.checkpointBatchSize == 0
                || checkpointMutations % LiveLocalSourcesCoordinator.checkpointBatchSize == 0 {
                try await onCheckpointAdvanced()
            }
        }
        return ingested
    }

    static func collectWritingSamples(mailRootURL: URL, selectedAccountIDs: Set<String>?, limit: Int = 15) throws -> [LiveWritingSample] {
        let versionDir = try locateVersionDirectory(mailRootURL: mailRootURL)
        let indexPath = versionDir.appending(path: "MailData/Envelope Index").path
        let (backupURL, tempDir) = try LiveSourceSQLite.walSafeCopy(of: indexPath, label: "Apple Mail")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reader = try LiveSourceSQLite.Reader(path: backupURL.path)
        let emlxIndex = indexEmlxFiles(in: versionDir)
        let rows = try loadEligibleMailRows(reader: reader, selectedAccountIDs: selectedAccountIDs)
            .filter(\.isSentMailbox)
            .sorted { MailIngestion.Position($0.mailRow) > MailIngestion.Position($1.mailRow) }

        var samples: [LiveWritingSample] = []
        for candidate in rows {
            guard samples.count < limit else { break }
            guard let emlxURL = emlxIndex[candidate.mailRow.id],
                  let parsed = parseEmlxFile(at: emlxURL, expectedMessageID: candidate.messageIDHeader) else { continue }
            let cleaned = stripQuotedReplyText(parsed.bodyText)
            guard !cleaned.isEmpty else { continue }
            samples.append(LiveWritingSample(
                source: .appleMail,
                recipient: parsed.to.isEmpty ? "Recipient" : parsed.to,
                subject: parsed.subject.isEmpty ? candidate.subject : parsed.subject,
                text: NativePersonalSources.bounded(cleaned, maximumBytes: 4_000),
                sentAt: candidate.mailRow.date
            ))
        }
        return samples
    }

    private struct CandidateMailRow {
        let mailRow: MailIngestion.Row
        let messageIDHeader: String?
        let subject: String
        let sender: String
        let isSentMailbox: Bool
    }

    private static func readIndexGeneration(reader: LiveSourceSQLite.Reader, fallbackPath: String) -> String {
        var uuid: String?
        if !reader.tableColumns("properties").isEmpty {
            try? reader.query("SELECT value FROM properties WHERE key IN ('UUID', 'uuid') LIMIT 1") { stmt in
                uuid = LiveSourceSQLite.Reader.text(stmt, 0)
            }
        }
        if let uuid, !uuid.isEmpty { return uuid }
        var st = stat()
        if fallbackPath.withCString({ lstat($0, &st) }) == 0 {
            return "inode-\(st.st_dev)-\(st.st_ino)"
        }
        return "default-envelope-index"
    }

    private static func mailboxSegments(from urlString: String) -> (account: String, mailboxName: String, isExcluded: Bool, isSent: Bool) {
        let components = URLComponents(string: urlString)
        let host = components?.host ?? "local"
        let decodedPath = (components?.percentEncodedPath.removingPercentEncoding ?? urlString)
        let segments = decodedPath
            .split(separator: "/")
            .map { String($0).replacingOccurrences(of: ".mbox", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let leafName = segments.last ?? "Inbox"
        let isExcluded = segments.contains { MailIngestion.MailboxFilter.isExcluded(mailboxName: $0) || MailIngestion.MailboxFilter.isHidden(mailboxName: $0) }
        let lowerPath = decodedPath.lowercased()
        let isSent = lowerPath.contains("/sent") || lowerPath.contains("sent messages") || lowerPath.contains("sent mail")
        return (host, leafName, isExcluded, isSent)
    }

    private static func loadEligibleMailRows(
        reader: LiveSourceSQLite.Reader,
        selectedAccountIDs: Set<String>?
    ) throws -> [CandidateMailRow] {
        var mailboxes: [Int64: (account: String, mailboxName: String, url: String, isExcluded: Bool, isSent: Bool)] = [:]
        try reader.query("SELECT ROWID, url FROM mailboxes WHERE url IS NOT NULL") { stmt in
            let rowID = LiveSourceSQLite.Reader.int64(stmt, 0)
            guard let urlString = LiveSourceSQLite.Reader.text(stmt, 1) else { return }
            let info = mailboxSegments(from: urlString)
            if let selectedAccountIDs, !selectedAccountIDs.isEmpty, !selectedAccountIDs.contains(info.account) {
                mailboxes[rowID] = (info.account, info.mailboxName, urlString, true, false)
                return
            }
            mailboxes[rowID] = (info.account, info.mailboxName, urlString, info.isExcluded, info.isSent)
        }

        var serverFlaggedRows = Set<Int64>()
        if !reader.tableColumns("server_messages").isEmpty {
            let smCols = reader.tableColumns("server_messages")
            let junkExpr = smCols.contains("junk_level") ? "COALESCE(junk_level, 0) > 0" : "0=1"
            try? reader.query("""
                SELECT message FROM server_messages
                WHERE COALESCE(deleted, 0) != 0 OR COALESCE(draft, 0) != 0 OR \(junkExpr)
                """) { stmt in
                serverFlaggedRows.insert(LiveSourceSQLite.Reader.int64(stmt, 0))
            }
        }

        let msgCols = reader.tableColumns("messages")
        let hasSubjectsTable = !reader.tableColumns("subjects").isEmpty
        let hasAddressesTable = !reader.tableColumns("addresses").isEmpty
        let hasMsgGlobalData = !reader.tableColumns("message_global_data").isEmpty

        let subjectSelect = hasSubjectsTable && msgCols.contains("subject") ? "s.subject" : (msgCols.contains("subject") ? "CAST(m.subject AS TEXT)" : "''")
        let subjectJoin = hasSubjectsTable && msgCols.contains("subject") ? "LEFT JOIN subjects s ON s.ROWID = m.subject" : ""
        let senderSelect = hasAddressesTable && msgCols.contains("sender") ? "COALESCE(a.comment, a.address, '')" : "''"
        let senderJoin = hasAddressesTable && msgCols.contains("sender") ? "LEFT JOIN addresses a ON a.ROWID = m.sender" : ""

        let deletedPred = msgCols.contains("deleted") ? "COALESCE(m.deleted, 0) = 0" : "1=1"
        let flagsExpr = msgCols.contains("flags") ? "m.flags" : "0"
        let messageIDCol = msgCols.contains("message_id") ? "CAST(m.message_id AS TEXT)" : "NULL"
        let messageIDHeaderCol = msgCols.contains("message_id_header") ? "m.message_id_header" : "NULL"
        let unsubPred = msgCols.contains("unsubscribe_type") ? "COALESCE(m.unsubscribe_type, 0) != 0" : "0=1"
        let listPred = msgCols.contains("list_id_hash") ? "m.list_id_hash IS NOT NULL AND m.list_id_hash != 0" : "0=1"

        var globalPromotionalIDs = Set<Int64>()
        if hasMsgGlobalData {
            let mgdCols = reader.tableColumns("message_global_data")
            if mgdCols.contains("model_category"), mgdCols.contains("ROWID") {
                try? reader.query("SELECT ROWID FROM message_global_data WHERE model_category = 3") { stmt in
                    globalPromotionalIDs.insert(LiveSourceSQLite.Reader.int64(stmt, 0))
                }
            }
        }
        let globalDataCol = msgCols.contains("global_message_id") ? "m.global_message_id" : "0"

        var taintedMessageKeys = Set<String>()
        var rawRows: [(rowID: Int64, mailboxID: Int64, dateReceived: Int64, key: String, headerID: String?, subject: String, sender: String, excludedCopy: Bool)] = []

        try reader.query("""
            SELECT m.ROWID, m.mailbox, COALESCE(m.date_received, m.date_sent, 0),
                   \(messageIDCol), \(messageIDHeaderCol), \(subjectSelect), \(senderSelect),
                   \(flagsExpr), CASE WHEN (\(unsubPred)) OR (\(listPred)) THEN 1 ELSE 0 END,
                   \(globalDataCol)
            FROM messages m
            \(subjectJoin)
            \(senderJoin)
            WHERE \(deletedPred)
            ORDER BY COALESCE(m.date_received, m.date_sent, 0) DESC, m.ROWID DESC
            LIMIT 25000
            """) { stmt in
            let rowID = LiveSourceSQLite.Reader.int64(stmt, 0)
            let mailboxID = LiveSourceSQLite.Reader.int64(stmt, 1)
            let dateReceived = LiveSourceSQLite.Reader.int64(stmt, 2)
            let msgIDNum = LiveSourceSQLite.Reader.text(stmt, 3) ?? ""
            let msgIDHeader = LiveSourceSQLite.Reader.text(stmt, 4)
            let subject = LiveSourceSQLite.Reader.text(stmt, 5) ?? ""
            let sender = LiveSourceSQLite.Reader.text(stmt, 6) ?? ""
            let flags = LiveSourceSQLite.Reader.int64(stmt, 7)
            let isBulkColumn = LiveSourceSQLite.Reader.int64(stmt, 8) != 0
            let globalID = LiveSourceSQLite.Reader.int64(stmt, 9)

            // Apple Mail bitflags: bit 1 = deleted, bit 6 (0x40) = draft, bit 21 (0x200000) = junk
            let flaggedTrashDraftJunk = (flags & 0x02) != 0 || (flags & 0x40) != 0 || (flags & 0x200_000) != 0
            let mailboxInfo = mailboxes[mailboxID]
            let inExcludedMailbox = mailboxInfo?.isExcluded ?? true
            let isSent = mailboxInfo?.isSent ?? false
            let isPromotional = !isSent && (isBulkColumn || globalPromotionalIDs.contains(globalID))
            let isTainted = inExcludedMailbox || flaggedTrashDraftJunk || serverFlaggedRows.contains(rowID) || isPromotional

            let stableKey = (msgIDHeader?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (!msgIDNum.isEmpty && msgIDNum != "0" ? "mid:\(msgIDNum)" : "row:\(rowID)")

            if isTainted && (flaggedTrashDraftJunk || serverFlaggedRows.contains(rowID) || (mailboxInfo?.isExcluded == true)) {
                taintedMessageKeys.insert(stableKey)
            }
            rawRows.append((rowID, mailboxID, dateReceived, stableKey, msgIDHeader, subject, sender, isTainted))
        }

        // Deduplicate by stable message key (All Mail + Inbox copies collapse cleanly, and any copy in Junk/Trash/Drafts taints all copies `SRC-13`)
        var seenKeys = Set<String>()
        var eligible: [CandidateMailRow] = []
        for entry in rawRows {
            guard !entry.excludedCopy, !taintedMessageKeys.contains(entry.key) else { continue }
            guard seenKeys.insert(entry.key).inserted else { continue }
            let mb = mailboxes[entry.mailboxID]
            let isSent = mb?.isSent ?? false
            eligible.append(CandidateMailRow(
                mailRow: MailIngestion.Row(
                    id: entry.rowID,
                    account: mb?.account ?? "local",
                    messageID: entry.key,
                    date: Date(timeIntervalSince1970: TimeInterval(entry.dateReceived)),
                    mailbox: mb?.mailboxName ?? "Inbox"
                ),
                messageIDHeader: entry.headerID,
                subject: entry.subject,
                sender: entry.sender,
                isSentMailbox: isSent
            ))
        }
        return eligible
    }

    static func indexEmlxFiles(in versionDir: URL, matchingRowIDs: Set<Int64>? = nil) -> [Int64: URL] {
        var map: [Int64: URL] = [:]
        if let matchingRowIDs, matchingRowIDs.isEmpty { return map }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(at: versionDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return map
        }
        var count = 0
        for case let url as URL in enumerator {
            guard count < maxIndexedEmlxFiles else { break }
            if let matchingRowIDs, map.count >= matchingRowIDs.count { break }
            if let values = try? url.resourceValues(forKeys: Set(keys)) {
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isDirectory == true {
                    let name = url.lastPathComponent
                    if name == "Attachments" || name == "MailData" {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true else { continue }
            }
            let name = url.lastPathComponent
            guard name.hasSuffix(".emlx") else { continue }
            // Skip `.partial.emlx` undownloaded stubs so checkpoint schedules retry until full `.emlx` arrives!
            if name.hasSuffix(".partial.emlx") { continue }
            let prefix = name.dropLast(".emlx".count)
            if let rowID = Int64(prefix) {
                if let matchingRowIDs, !matchingRowIDs.contains(rowID) {
                    count += 1
                    continue
                }
                map[rowID] = url
                count += 1
            }
        }
        return map
    }

    static func parseEmlxFile(at url: URL, expectedMessageID: String? = nil) -> ParsedEmlx? {
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0, st.st_size <= maxEmlxBytes else { return nil }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: maxEmlxBytes), !data.isEmpty else { return nil }
        return parseEmlxData(data, expectedMessageID: expectedMessageID)
    }

    static func parseEmlxData(_ data: Data, expectedMessageID: String? = nil) -> ParsedEmlx? {
        let bytes = [UInt8](data)
        // `.emlx` starts with `<decimal byte count>\n<RFC822 message><Apple plist trailer>`
        var newlineIdx: Int?
        for i in 0..<min(bytes.count, 32) where bytes[i] == 0x0A {
            newlineIdx = i
            break
        }
        let rfc822Slice: Data
        if let nl = newlineIdx,
           let countStr = String(bytes: bytes[0..<nl], encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let declaredCount = Int(countStr), declaredCount > 0, nl + 1 + declaredCount <= bytes.count {
            rfc822Slice = Data(bytes[(nl + 1)..<(nl + 1 + declaredCount)])
        } else {
            rfc822Slice = data
        }

        let (headers, bodyBytes) = splitRFC822(rfc822Slice)
        let messageID = headers["message-id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expected = expectedMessageID?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty {
            guard let actual = messageID, actual == expected else { return nil }
        }

        let subject = decodeRFC2047(headers["subject"] ?? "")
        let from = decodeRFC2047(headers["from"] ?? "")
        let to = decodeRFC2047(headers["to"] ?? "")
        let listUnsub = headers["list-unsubscribe"] != nil
        let listID = headers["list-id"] != nil
        let prec = (headers["precedence"] ?? "").lowercased()
        let isBulk = prec.contains("bulk") || prec.contains("list") || prec.contains("junk")

        let extractedBody = extractMIMEBody(headers: headers, body: bodyBytes, depth: 0)
        return ParsedEmlx(
            messageIDHeader: messageID,
            from: from,
            to: to,
            subject: subject,
            listUnsubscribe: listUnsub,
            listID: listID,
            precedenceBulk: isBulk,
            rawHeaders: headers,
            bodyText: extractedBody
        )
    }

    private static func splitRFC822(_ data: Data) -> ([String: String], Data) {
        let bytes = [UInt8](data)
        var sepStart = bytes.count
        var bodyStart = bytes.count
        var i = 0
        while i < bytes.count - 1 {
            if bytes[i] == 0x0D, i + 3 < bytes.count, bytes[i + 1] == 0x0A, bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A {
                sepStart = i
                bodyStart = i + 4
                break
            }
            if bytes[i] == 0x0A, bytes[i + 1] == 0x0A {
                sepStart = i
                bodyStart = i + 2
                break
            }
            i += 1
        }
        let headerString = String(decoding: bytes[0..<sepStart], as: UTF8.self)
        var unfoldedLines: [String] = []
        for rawLine in headerString.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty { continue }
            if let first = line.first, (first == " " || first == "\t"), !unfoldedLines.isEmpty {
                unfoldedLines[unfoldedLines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfoldedLines.append(line)
            }
        }
        var dict: [String: String] = [:]
        for line in unfoldedLines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if dict[name] == nil {
                dict[name] = value
            }
        }
        let body = bodyStart < bytes.count ? Data(bytes[bodyStart...]) : Data()
        return (dict, body)
    }

    private static func extractMIMEBody(headers: [String: String], body: Data, depth: Int) -> String {
        guard depth <= 6 else { return "" }
        let contentType = headers["content-type"] ?? "text/plain; charset=utf-8"
        let disposition = headers["content-disposition"]
        let transferEncoding = (headers["content-transfer-encoding"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let mediaType = contentType.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? "text/plain"

        if mediaType.hasPrefix("multipart/") {
            guard let boundary = mimeParameter("boundary", in: contentType) else { return "" }
            let parts = splitMultipart(body: body, boundary: boundary)
            var plainParts: [String] = []
            var htmlParts: [String] = []
            for partData in parts {
                let (partHeaders, partBody) = splitRFC822(partData)
                let partType = (partHeaders["content-type"] ?? "text/plain").lowercased()
                let text = extractMIMEBody(headers: partHeaders, body: partBody, depth: depth + 1)
                guard !text.isEmpty else { continue }
                if partType.hasPrefix("text/html") {
                    htmlParts.append(text)
                } else {
                    plainParts.append(text)
                }
            }
            if !plainParts.isEmpty {
                return plainParts.joined(separator: "\n\n")
            }
            return htmlParts.joined(separator: "\n\n")
        }

        if let disp = disposition?.lowercased(), disp.hasPrefix("attachment") {
            return ""
        }

        let decodedBytes = decodeTransferEncoding(body, encoding: transferEncoding)
        let charset = mimeParameter("charset", in: contentType) ?? "utf-8"

        if mediaType == "text/plain" {
            return decodeCharset(decodedBytes, charset: charset)
        }
        if mediaType == "text/html" {
            let html = decodeCharset(decodedBytes, charset: charset)
            return stripHTMLToText(html)
        }
        return ""
    }

    private static func mimeParameter(_ name: String, in headerValue: String) -> String? {
        for segment in headerValue.split(separator: ";").dropFirst() {
            let parts = segment.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == name.lowercased() else { continue }
            var val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val.removeFirst()
                val.removeLast()
            }
            return val
        }
        return nil
    }

    private static func splitMultipart(body: Data, boundary: String) -> [Data] {
        let delimiter = Data(("--" + boundary).utf8)
        var parts: [Data] = []
        var searchRange = body.startIndex..<body.endIndex
        var previousPartStart: Int?

        while let match = body.range(of: delimiter, options: [], in: searchRange) {
            if let start = previousPartStart {
                var end = match.lowerBound
                if end >= 2, body[end - 2] == 0x0D, body[end - 1] == 0x0A {
                    end -= 2
                } else if end >= 1, body[end - 1] == 0x0A {
                    end -= 1
                }
                if end > start {
                    parts.append(body.subdata(in: start..<end))
                }
            }
            let afterDelim = match.upperBound
            if afterDelim + 2 <= body.endIndex, body[afterDelim] == 0x2D, body[afterDelim + 1] == 0x2D {
                break
            }
            var nextStart = afterDelim
            while nextStart < body.endIndex, body[nextStart] == 0x20 || body[nextStart] == 0x09 {
                nextStart += 1
            }
            if nextStart + 2 <= body.endIndex, body[nextStart] == 0x0D, body[nextStart + 1] == 0x0A {
                nextStart += 2
            } else if nextStart < body.endIndex, body[nextStart] == 0x0A {
                nextStart += 1
            }
            previousPartStart = nextStart
            searchRange = nextStart..<body.endIndex
            if parts.count >= 32 { break }
        }
        return parts
    }

    private static func decodeTransferEncoding(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let cleaned = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned) ?? data
        case "quoted-printable":
            let bytes = [UInt8](data)
            var out = Data()
            out.reserveCapacity(bytes.count)
            var i = 0
            while i < bytes.count {
                if bytes[i] == 0x3D { // '='
                    if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                        i += 3
                        continue
                    }
                    if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                        i += 2
                        continue
                    }
                    if i + 2 < bytes.count,
                       let hi = hexVal(bytes[i + 1]),
                       let lo = hexVal(bytes[i + 2]) {
                        out.append((hi << 4) | lo)
                        i += 3
                        continue
                    }
                }
                out.append(bytes[i])
                i += 1
            }
            return out
        default:
            return data
        }
    }

    private static func hexVal(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 65...70: return b - 55
        case 97...102: return b - 87
        default: return nil
        }
    }

    private static func decodeCharset(_ data: Data, charset: String) -> String {
        switch charset.lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii":
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        case "iso-8859-1", "latin1":
            return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        case "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        default:
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        }
    }

    static func stripHTMLToText(_ html: String) -> String {
        // Pure Swift HTML tag & script/style stripper (never invokes WebKit / network!).
        var s = html
        for blocked in ["script", "style", "head"] {
            while let openRange = s.range(of: "<\(blocked)", options: .caseInsensitive) {
                if let closeRange = s.range(of: "</\(blocked)>", options: .caseInsensitive, range: openRange.lowerBound..<s.endIndex) {
                    s.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                } else {
                    s.removeSubrange(openRange.lowerBound..<s.endIndex)
                    break
                }
            }
        }
        var out = String()
        out.reserveCapacity(min(s.count, 16_384))
        var inTag = false
        var tagName = ""
        for ch in s {
            if ch == "<" {
                inTag = true
                tagName = ""
            } else if ch == ">" {
                inTag = false
                let lower = tagName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lower.hasPrefix("br") || lower.hasPrefix("/p") || lower.hasPrefix("/div") || lower.hasPrefix("/li") || lower.hasPrefix("/tr") {
                    out.append("\n")
                }
            } else if inTag {
                if tagName.count < 16 { tagName.append(ch) }
            } else {
                out.append(ch)
            }
        }
        return out
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func decodeRFC2047(_ raw: String) -> String {
        guard raw.contains("=?") else { return raw }
        var result = raw
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).reversed()
        for match in matches {
            guard match.numberOfRanges == 4,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let charsetRange = Range(match.range(at: 1), in: result),
                  let encRange = Range(match.range(at: 2), in: result),
                  let payloadRange = Range(match.range(at: 3), in: result) else { continue }
            let charset = String(result[charsetRange])
            let enc = result[encRange].lowercased()
            let payload = String(result[payloadRange])
            let decodedData: Data
            if enc == "b" {
                decodedData = Data(base64Encoded: payload) ?? Data()
            } else {
                let qp = payload.replacingOccurrences(of: "_", with: " ")
                decodedData = decodeTransferEncoding(Data(qp.utf8), encoding: "quoted-printable")
            }
            let decodedText = decodeCharset(decodedData, charset: charset)
            result.replaceSubrange(fullRange, with: decodedText)
        }
        return result
    }

    private static func stripQuotedReplyText(_ body: String) -> String {
        var lines: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { continue }
            if trimmed.hasPrefix("On "), trimmed.hasSuffix("wrote:") { break }
            if trimmed == "-----Original Message-----" { break }
            lines.append(line)
        }
        return LiveMessageBodyDecoder.cleanText(lines.joined(separator: "\n"))
    }
}

// MARK: - Observable MainActor Coordinator

@Observable @MainActor
final class LiveLocalSourcesCoordinator {
    nonisolated struct PersistedConfig: Codable, Equatable, Sendable {
        static let currentVersion = 1
        var version = Self.currentVersion
        var enabledSources: Set<LiveLocalSourceKind> = []
        var selectedIMessageChatGUIDs: Set<String> = []
        var selectedWhatsAppChatJIDs: Set<String> = []
        var selectedMailAccountIDs: Set<String> = []
    }

    nonisolated static let maximumPersistedItems = 2_000
    nonisolated static let checkpointBatchSize = 25
    nonisolated static let maximumItemsStateBytes = LocalPrivateFileWriter.maximumSupportedBytes

    private struct SyncWaiter {
        let id: UUID
        let continuation: CheckedContinuation<[LiveIngestedItem], any Error>
    }

    private final class ActiveSyncOperation {
        let id = UUID()
        let coveredSources: Set<LiveLocalSourceKind>
        var waiters: [SyncWaiter] = []
        var activeWaiterIDs: Set<UUID> = []
        var task: Task<Void, Never>?
        var completedResult: Result<[LiveIngestedItem], any Error>?

        init(coveredSources: Set<LiveLocalSourceKind>) {
            self.coveredSources = coveredSources
        }
    }

    private(set) var fullDiskAccessStatus: FullDiskAccessStatus
    private(set) var enabledSources: Set<LiveLocalSourceKind> = []
    private(set) var selectedIMessageChatGUIDs: Set<String> = []
    private(set) var selectedWhatsAppChatJIDs: Set<String> = []
    private(set) var selectedMailAccountIDs: Set<String> = []

    private(set) var availableIMessageChats: [LiveChatDescriptor] = []
    private(set) var availableWhatsAppChats: [LiveChatDescriptor] = []
    private(set) var availableMailAccounts: [LiveMailAccountDescriptor] = []

    private(set) var ingestedItems: [LiveIngestedItem] = [] {
        didSet {
            cachedKnowledgeRecords = nil
        }
    }
    var hasIngestedItems: Bool { !ingestedItems.isEmpty }
    private(set) var isSyncing = false
    private(set) var status = "Live incremental local sync is off until you opt into a source."
    private(set) var lastErrorMessage: String?
    private(set) var sourceStatuses: [LiveLocalSourceKind: String] = [:]

    let paths: LiveLocalSourcePaths
    let checkpointStore: LiveSourceCheckpointStore

    @ObservationIgnored var onItemsIngested: (@MainActor ([LiveIngestedItem]) async throws -> Void)?
    @ObservationIgnored var onContextChanged: (() -> Void)?
    @ObservationIgnored private let configURL: URL?
    @ObservationIgnored private let itemsURL: URL?
    @ObservationIgnored private let probeOverride: (() -> FullDiskAccessStatus)?
    @ObservationIgnored private var activeSyncOperation: ActiveSyncOperation?
    @ObservationIgnored private var cachedKnowledgeRecords: (sources: Set<LiveLocalSourceKind>, records: [KnowledgeRecord])?

    static var defaultDirectoryURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Relay", directoryHint: .isDirectory)
    }

    init(
        paths: LiveLocalSourcePaths = .defaultLivePaths,
        checkpointStore: LiveSourceCheckpointStore? = nil,
        directoryURL: URL? = LiveLocalSourcesCoordinator.defaultDirectoryURL,
        fullDiskAccessProbe: (() -> FullDiskAccessStatus)? = nil
    ) {
        self.paths = paths
        self.probeOverride = fullDiskAccessProbe
        self.configURL = directoryURL?.appending(path: "live-sources-config.json")
        self.itemsURL = directoryURL?.appending(path: "live-sources-items.json")
        self.checkpointStore = checkpointStore ?? LiveSourceCheckpointStore(
            fileURL: directoryURL?.appending(path: "live-source-checkpoints.json")
        )
        self.fullDiskAccessStatus = fullDiskAccessProbe?() ?? FullDiskAccessDetector.probe(paths: paths.fdaProbePaths)
        restoreState()
    }

    var isWhatsAppInstalled: Bool {
        LiveWhatsAppReader.isInstalled(databaseURL: paths.whatsappDatabaseURL)
    }

    @discardableResult
    func refreshFullDiskAccessStatus() -> FullDiskAccessStatus {
        let next = probeOverride?() ?? FullDiskAccessDetector.probe(paths: paths.fdaProbePaths)
        fullDiskAccessStatus = next
        return next
    }

    @discardableResult
    func openFullDiskAccessSettings() -> Bool {
        FullDiskAccessDetector.openSystemSettings()
    }

    func isEnabled(_ kind: LiveLocalSourceKind) -> Bool {
        enabledSources.contains(kind)
    }

    func setEnabled(_ kind: LiveLocalSourceKind, _ enabled: Bool) {
        if enabled {
            enabledSources.insert(kind)
            sourceStatuses[kind] = "Enabled for incremental checkpointed sync."
        } else {
            enabledSources.remove(kind)
            sourceStatuses[kind] = "Paused."
        }
        persistConfig()
        onContextChanged?()
    }

    func setSelectedIMessageChats(_ guids: Set<String>) {
        selectedIMessageChatGUIDs = guids
        persistConfig()
    }

    func setSelectedWhatsAppChats(_ jids: Set<String>) {
        selectedWhatsAppChatJIDs = jids
        persistConfig()
    }

    func setSelectedMailAccounts(_ accountIDs: Set<String>) {
        selectedMailAccountIDs = accountIDs
        persistConfig()
    }

    func refreshPickers() async {
        _ = refreshFullDiskAccessStatus()
        let currentPaths = paths
        let fdaGranted = fullDiskAccessStatus.granted
        let result = await Task.detached(priority: .userInitiated) { () -> ([LiveChatDescriptor], [LiveChatDescriptor], [LiveMailAccountDescriptor]) in
            let imessage = fdaGranted
                ? ((try? LiveIMessageReader.listChats(databaseURL: currentPaths.messagesDatabaseURL, addressBookRootURL: currentPaths.addressBookRootURL)) ?? [])
                : []
            let whatsapp = (try? LiveWhatsAppReader.listChats(databaseURL: currentPaths.whatsappDatabaseURL)) ?? []
            let mail = fdaGranted
                ? ((try? LiveAppleMailReader.listAccounts(mailRootURL: currentPaths.mailRootURL)) ?? [])
                : []
            return (imessage, whatsapp, mail)
        }.value

        availableIMessageChats = result.0
        availableWhatsAppChats = result.1
        availableMailAccounts = result.2
    }

    /// Runs incremental checkpointed ingestion across opted-in live sources (`TRI-05`, `TRI-06`).
    /// Coalesces overlapping callers onto the active sync pass instead of throwing `.busy`, and persists
    /// `ingestedItems` BEFORE flushing SQLite checkpoints (every 25 items and at source completion / cancellation).
    @discardableResult
    func runIncrementalIngestion(
        sources: Set<LiveLocalSourceKind>? = nil,
        maxItemsPerSource: Int = 75,
        now: Date = Date(),
        coalesceIfBusy: Bool = true
    ) async throws -> [LiveIngestedItem] {
        try Task.checkCancellation()
        if let existing = activeSyncOperation {
            guard coalesceIfBusy else { throw LiveLocalSourceError.busy }
            let coalesced = try await awaitSyncOperation(existing)
            try Task.checkCancellation()
            let requested = (sources ?? enabledSources).intersection(enabledSources)
            let missing = requested.subtracting(existing.coveredSources)
            var filtered = sources == nil ? coalesced : coalesced.filter { requested.contains($0.source) }
            if !missing.isEmpty {
                let extra = try await runIncrementalIngestion(
                    sources: missing,
                    maxItemsPerSource: maxItemsPerSource,
                    now: now,
                    coalesceIfBusy: coalesceIfBusy
                )
                filtered.append(contentsOf: extra)
            }
            return filtered
        }

        let targetSources = (sources ?? enabledSources).intersection(enabledSources)
        guard !targetSources.isEmpty else {
            status = "No live local sources are enabled."
            return []
        }

        let operation = ActiveSyncOperation(coveredSources: targetSources)
        activeSyncOperation = operation
        isSyncing = true
        lastErrorMessage = nil

        operation.task = Task { @MainActor [weak self] in
            guard let self else {
                let waiters = operation.waiters
                operation.waiters.removeAll()
                operation.activeWaiterIDs.removeAll()
                operation.completedResult = .failure(CancellationError())
                for waiter in waiters {
                    waiter.continuation.resume(throwing: CancellationError())
                }
                return
            }
            let result: Result<[LiveIngestedItem], any Error>
            do {
                let items = try await self.performIncrementalPass(
                    operationID: operation.id,
                    targetSources: targetSources,
                    maxItemsPerSource: maxItemsPerSource,
                    now: now
                )
                result = .success(items)
            } catch {
                result = .failure(error)
            }
            if operation.completedResult == nil {
                operation.completedResult = result
            }
            if self.activeSyncOperation === operation {
                self.activeSyncOperation = nil
                self.isSyncing = false
            }
            let waiters = operation.waiters
            operation.waiters.removeAll()
            operation.activeWaiterIDs.removeAll()
            let finalResult = operation.completedResult ?? result
            for waiter in waiters {
                waiter.continuation.resume(with: finalResult)
            }
        }

        return try await awaitSyncOperation(operation)
    }

    func cancelSync() {
        guard let operation = activeSyncOperation else { return }
        status = "Stopping live source sync…"
        operation.task?.cancel()
    }

    func recordSyncError(_ error: any Error) {
        if error is CancellationError {
            status = "Live sync paused; will resume from exact checkpoint."
            return
        }
        let detail = error.localizedDescription
        lastErrorMessage = detail
        status = detail
    }

    private func awaitSyncOperation(_ operation: ActiveSyncOperation) async throws -> [LiveIngestedItem] {
        let waiterID = UUID()
        let operationID = operation.id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    if operation.activeWaiterIDs.isEmpty, operation.completedResult == nil {
                        operation.task?.cancel()
                    }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let result = operation.completedResult {
                    continuation.resume(with: result)
                    return
                }
                operation.activeWaiterIDs.insert(waiterID)
                operation.waiters.append(SyncWaiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.handleSyncWaiterCancellation(waiterID: waiterID, operationID: operationID)
            }
        }
    }

    private func handleSyncWaiterCancellation(waiterID: UUID, operationID: UUID) {
        guard let operation = activeSyncOperation,
              operation.id == operationID,
              operation.completedResult == nil else { return }
        operation.activeWaiterIDs.remove(waiterID)
        if operation.activeWaiterIDs.isEmpty {
            operation.task?.cancel()
        } else if let idx = operation.waiters.firstIndex(where: { $0.id == waiterID }) {
            let removed = operation.waiters.remove(at: idx)
            removed.continuation.resume(throwing: CancellationError())
        }
    }

    @MainActor
    private final class IncrementalPassAccumulator {
        var newlyIngested: [LiveIngestedItem] = []
        var streamedForKind = 0
    }

    private func performIncrementalPass(
        operationID: UUID,
        targetSources: Set<LiveLocalSourceKind>,
        maxItemsPerSource: Int,
        now: Date
    ) async throws -> [LiveIngestedItem] {
        checkpointStore.setBatchingEnabled(true)
        defer { checkpointStore.setBatchingEnabled(false) }

        _ = refreshFullDiskAccessStatus()
        let accumulator = IncrementalPassAccumulator()
        var sourceErrors: [String] = []
        var waitingForFDA: [LiveLocalSourceKind] = []

        status = "Syncing \(targetSources.count) enabled source(s)…"

        for kind in LiveLocalSourceKind.allCases where targetSources.contains(kind) {
            try Task.checkCancellation()
            guard activeSyncOperation?.id == operationID else { throw CancellationError() }
            if (kind == .notes || kind == .appleMail || kind == .imessage), !fullDiskAccessStatus.granted {
                waitingForFDA.append(kind)
                sourceStatuses[kind] = "Waiting for Full Disk Access."
                continue
            }
            if kind == .whatsapp, !FileManager.default.fileExists(atPath: paths.whatsappDatabaseURL.path) {
                sourceStatuses[kind] = "WhatsApp database not found on this Mac."
                continue
            }

            sourceStatuses[kind] = "Syncing \(kind.title)…"
            status = "Syncing \(kind.title)…"
            do {
                accumulator.streamedForKind = 0
                let appendItem: @MainActor @Sendable (LiveIngestedItem) async throws -> Void = { [weak self] item in
                    try Task.checkCancellation()
                    guard let self, self.activeSyncOperation?.id == operationID else { throw CancellationError() }
                    if let callback = self.onItemsIngested {
                        try await callback([item])
                    }
                    try Task.checkCancellation()
                    guard self.activeSyncOperation?.id == operationID else { throw CancellationError() }
                    self.recordIngestedItem(item)
                    accumulator.newlyIngested.append(item)
                    accumulator.streamedForKind += 1
                    self.sourceStatuses[kind] = "Syncing \(kind.title)… (\(accumulator.streamedForKind) item(s))"
                    self.status = "Syncing \(kind.title)… (\(accumulator.newlyIngested.count) new item(s))"
                }
                let flushBatch: @MainActor @Sendable () async throws -> Void = { [weak self] in
                    guard let self, self.activeSyncOperation?.id == operationID else { return }
                    try self.flushItemsAndCheckpoints()
                }

                let currentPaths = paths
                let store = checkpointStore
                let imessageFilter = selectedIMessageChatGUIDs.isEmpty ? nil : selectedIMessageChatGUIDs
                let whatsappFilter = selectedWhatsAppChatJIDs.isEmpty ? nil : selectedWhatsAppChatJIDs
                let mailFilter = selectedMailAccountIDs.isEmpty ? nil : selectedMailAccountIDs
                let readerTask = Task.detached(priority: .utility) { () throws -> Int in
                    switch kind {
                    case .notes:
                        return try await LiveAppleNotesReader.readIncremental(
                            databaseURL: currentPaths.notesDatabaseURL,
                            checkpointStore: store,
                            maxItemsPerPass: maxItemsPerSource,
                            onItem: appendItem,
                            onCheckpointAdvanced: flushBatch
                        )
                    case .imessage:
                        return try await LiveIMessageReader.readIncremental(
                            databaseURL: currentPaths.messagesDatabaseURL,
                            addressBookRootURL: currentPaths.addressBookRootURL,
                            selectedChatGUIDs: imessageFilter,
                            checkpointStore: store,
                            now: now,
                            maxWindowsPerPass: maxItemsPerSource,
                            onItem: appendItem,
                            onCheckpointAdvanced: flushBatch
                        )
                    case .whatsapp:
                        return try await LiveWhatsAppReader.readIncremental(
                            databaseURL: currentPaths.whatsappDatabaseURL,
                            selectedChatJIDs: whatsappFilter,
                            checkpointStore: store,
                            now: now,
                            maxWindowsPerPass: maxItemsPerSource,
                            onItem: appendItem,
                            onCheckpointAdvanced: flushBatch
                        )
                    case .appleMail:
                        return try await LiveAppleMailReader.readIncremental(
                            mailRootURL: currentPaths.mailRootURL,
                            selectedAccountIDs: mailFilter,
                            checkpointStore: store,
                            now: now,
                            maxItemsPerPass: maxItemsPerSource,
                            onItem: appendItem,
                            onCheckpointAdvanced: flushBatch
                        )
                    }
                }
                let countForKind = try await withTaskCancellationHandler {
                    try await readerTask.value
                } onCancel: {
                    readerTask.cancel()
                }

                if activeSyncOperation?.id == operationID {
                    try flushItemsAndCheckpoints()
                }
                let totalForKind = ingestedItems.count { $0.source == kind }
                sourceStatuses[kind] = countForKind > 0
                    ? "Synced \(countForKind) new item(s) (\(totalForKind) cached, checkpoint saved)."
                    : "Up to date (\(totalForKind) cached, checkpoint saved)."
            } catch is CancellationError {
                if activeSyncOperation?.id == operationID {
                    try? flushItemsAndCheckpoints()
                    sourceStatuses[kind] = "Paused at exact item checkpoint."
                    status = "Live sync paused; will resume from exact checkpoint."
                }
                throw CancellationError()
            } catch {
                if activeSyncOperation?.id == operationID {
                    try? flushItemsAndCheckpoints()
                }
                let detail = error.localizedDescription
                sourceStatuses[kind] = detail
                sourceErrors.append("\(kind.title): \(detail)")
            }
        }

        if activeSyncOperation?.id == operationID {
            try flushItemsAndCheckpoints()
        }
        let newlyIngested = accumulator.newlyIngested
        if !newlyIngested.isEmpty {
            onContextChanged?()
        }
        if !sourceErrors.isEmpty {
            let joined = sourceErrors.joined(separator: " • ")
            lastErrorMessage = joined
            status = newlyIngested.isEmpty
                ? "Sync finished with error(s): \(joined)"
                : "Synced \(newlyIngested.count) new item(s) with error(s): \(joined)"
        } else if !waitingForFDA.isEmpty, newlyIngested.isEmpty, waitingForFDA.count == targetSources.count {
            status = "Waiting for Full Disk Access to sync \(waitingForFDA.map(\.title).joined(separator: ", "))."
        } else {
            status = newlyIngested.isEmpty
                ? "All enabled live sources are up to date."
                : "Synced \(newlyIngested.count) new item(s) across enabled live sources."
        }
        return newlyIngested
    }

    func collectWritingSamples() async -> [LiveWritingSample] {
        _ = refreshFullDiskAccessStatus()
        let currentPaths = paths
        let fda = fullDiskAccessStatus.granted
        let enabled = enabledSources
        let imessageFilter = selectedIMessageChatGUIDs.isEmpty ? nil : selectedIMessageChatGUIDs
        let whatsappFilter = selectedWhatsAppChatJIDs.isEmpty ? nil : selectedWhatsAppChatJIDs
        let mailFilter = selectedMailAccountIDs.isEmpty ? nil : selectedMailAccountIDs

        return await Task.detached(priority: .utility) {
            var samples: [LiveWritingSample] = []
            if fda, enabled.contains(.appleMail),
               let mailSamples = try? LiveAppleMailReader.collectWritingSamples(mailRootURL: currentPaths.mailRootURL, selectedAccountIDs: mailFilter) {
                samples.append(contentsOf: mailSamples)
            }
            if fda, enabled.contains(.imessage),
               let imSamples = try? LiveIMessageReader.collectWritingSamples(databaseURL: currentPaths.messagesDatabaseURL, addressBookRootURL: currentPaths.addressBookRootURL, selectedChatGUIDs: imessageFilter) {
                samples.append(contentsOf: imSamples)
            }
            if enabled.contains(.whatsapp),
               let waSamples = try? LiveWhatsAppReader.collectWritingSamples(databaseURL: currentPaths.whatsappDatabaseURL, selectedChatJIDs: whatsappFilter) {
                samples.append(contentsOf: waSamples)
            }
            return samples
        }.value
    }

    func knowledgeRecords() -> [KnowledgeRecord] {
        if let cached = cachedKnowledgeRecords, cached.sources == enabledSources {
            return cached.records
        }
        let built = ingestedItems
            .filter { enabledSources.contains($0.source) }
            .map { $0.toKnowledgeRecord() }
        cachedKnowledgeRecords = (enabledSources, built)
        return built
    }

    func items(for kind: LiveLocalSourceKind) -> [LiveIngestedItem] {
        ingestedItems.filter { $0.source == kind }
    }

    func forgetSource(_ kind: LiveLocalSourceKind) {
        ingestedItems.removeAll { $0.source == kind }
        try? checkpointStore.wipeSource(kind)
        sourceStatuses[kind] = "Forgot cached items and reset checkpoint for \(kind.title)."
        lastErrorMessage = nil
        persistItems()
        onContextChanged?()
    }

    func resetAll() {
        if let operation = activeSyncOperation {
            operation.completedResult = .failure(CancellationError())
            operation.task?.cancel()
            let waiters = operation.waiters
            operation.waiters.removeAll()
            operation.activeWaiterIDs.removeAll()
            for waiter in waiters {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
        activeSyncOperation = nil
        isSyncing = false
        enabledSources.removeAll()
        selectedIMessageChatGUIDs.removeAll()
        selectedWhatsAppChatJIDs.removeAll()
        selectedMailAccountIDs.removeAll()
        ingestedItems.removeAll()
        sourceStatuses.removeAll()
        lastErrorMessage = nil
        try? checkpointStore.wipeAll()
        if let configURL { try? FileManager.default.removeItem(at: configURL) }
        if let itemsURL { try? FileManager.default.removeItem(at: itemsURL) }
        status = "Cleared all live source opt-ins, cached items, and checkpoints."
        onContextChanged?()
    }

    private func recordIngestedItem(_ item: LiveIngestedItem) {
        if let idx = ingestedItems.firstIndex(where: { $0.id == item.id }) {
            ingestedItems[idx] = item
        } else {
            ingestedItems.append(item)
        }
        if ingestedItems.count > Self.maximumPersistedItems {
            ingestedItems.sort { $0.timestamp > $1.timestamp }
            ingestedItems = Array(ingestedItems.prefix(Self.maximumPersistedItems))
        }
    }

    private func restoreState() {
        if let configURL,
           let data = try? LocalStateFile.read(configURL, maximumBytes: 512 * 1_024),
           let decoded = try? JSONDecoder().decode(PersistedConfig.self, from: data),
           decoded.version == PersistedConfig.currentVersion {
            enabledSources = decoded.enabledSources
            selectedIMessageChatGUIDs = decoded.selectedIMessageChatGUIDs
            selectedWhatsAppChatJIDs = decoded.selectedWhatsAppChatJIDs
            selectedMailAccountIDs = decoded.selectedMailAccountIDs
        }
        if let itemsURL,
           let data = try? LocalStateFile.read(itemsURL, maximumBytes: Self.maximumItemsStateBytes),
           let decoded = try? JSONDecoder().decode([LiveIngestedItem].self, from: data) {
            ingestedItems = decoded
        }
    }

    private func persistConfig() {
        guard let configURL else { return }
        let directory = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let payload = PersistedConfig(
            enabledSources: enabledSources,
            selectedIMessageChatGUIDs: selectedIMessageChatGUIDs,
            selectedWhatsAppChatJIDs: selectedWhatsAppChatJIDs,
            selectedMailAccountIDs: selectedMailAccountIDs
        )
        if let data = try? JSONEncoder().encode(payload) {
            try? LocalPrivateFileWriter.write(data: data, to: configURL, maximumBytes: 512 * 1_024)
        }
    }

    /// Persists `ingestedItems` to disk FIRST, and only then flushes advanced SQLite checkpoints to disk.
    private func flushItemsAndCheckpoints() throws {
        try persistItemsThrowing()
        try checkpointStore.flush()
    }

    private func persistItemsThrowing() throws {
        guard let itemsURL else { return }
        let directory = itemsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(ingestedItems)
        try LocalPrivateFileWriter.write(data: data, to: itemsURL, maximumBytes: Self.maximumItemsStateBytes)
    }

    private func persistItems() {
        try? persistItemsThrowing()
    }
}

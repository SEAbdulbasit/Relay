import CryptoKit
import Darwin
import Dispatch
import Foundation
import SQLite3

nonisolated struct NotesImportCoverage: Sendable, Equatable {
    var scanned = 0, resumed = 0, malformed = 0, undownloaded = 0, oversized = 0, blank = 0, excluded = 0
    var capped = false
    var description: String {
        "Apple Notes backup: \(scanned) eligible items checked; \(resumed) resumed from exact-source checkpoints. "
            + "\(excluded) protected/deleted/unsupported-state items excluded; \(undownloaded) unavailable, \(malformed) undecodable, \(oversized) oversized, \(blank) blank. "
            + (capped ? "Partial coverage: the 1,000-item window was reached. " : "")
            + "Plain text only; attachments, formatting and account attribution are unavailable. This is a chosen backup, not the live Notes app."
    }
}

/// Transient currentness observation of the actual chosen standalone backup.
/// No Codable/source-grant constructor exists; checkpoint bytes cannot mint it.
nonisolated struct NotesBackupIdentity: Sendable {
    let canonicalURL: URL
    let sourceDigest: String
    private let selectedURL: URL
    private let metadata: LocalStateFile.Metadata
    fileprivate init(selected: URL, canonical: URL, snapshot: LocalStateFile.Snapshot) {
        selectedURL = selected; canonicalURL = canonical; metadata = snapshot.metadata
        sourceDigest = NotesImportCheckpoint.digest(snapshot.data)
    }
    func validateCurrent() throws {
        try Task.checkCancellation()
        guard try ToolPolicy.canonicalURL(selectedURL.path) == canonicalURL else { throw NotesDatabaseIngestion.Failure.changed }
        try LocalStateFile.validateCurrent(metadata, at: selectedURL, maximumBytes: NotesDatabaseIngestion.maximumSnapshotBytes)
        try LocalStateFile.validateCurrent(metadata, at: canonicalURL, maximumBytes: NotesDatabaseIngestion.maximumSnapshotBytes)
        try NotesDatabaseIngestion.requireStandalone(canonicalURL)
    }
    fileprivate var checkpointIdentity: String {
        let fields = [Data(canonicalURL.path.utf8), Data(String(metadata.device).utf8), Data(String(metadata.inode).utf8), Data(sourceDigest.utf8)]
        var bytes = Data()
        for field in fields {
            var length = UInt64(field.count).bigEndian
            Swift.withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }; bytes.append(field)
        }
        return NotesImportCheckpoint.digest(bytes)
    }
}

/// One app-lifetime physical import owner. Cancelling a waiter never permits a
/// replacement until the actual bounded file/SQLite/decoder work has settled.
actor NotesDatabaseIngestion {
    private actor Reader {
        private let executorQueue = DispatchSerialQueue(label: "relay.notes-database-ingestion.reader")
        nonisolated var unownedExecutor: UnownedSerialExecutor {
            executorQueue.asUnownedSerialExecutor()
        }
        func read(_ selected: URL, checkpointRoot: URL,
                  checkpointObserver: NotesImportCheckpoint.Observer?) throws -> NativePersonalSourceBatch {
            try NotesDatabaseIngestion.readSync(selected, checkpointRoot: checkpointRoot, checkpointObserver: checkpointObserver)
        }
        func removeCheckpoints(_ root: URL) throws {
            try NotesImportCheckpoint.forget(root)
        }
    }
    nonisolated static let shared = NotesDatabaseIngestion()
    nonisolated static let maximumNotes = 1_000
    nonisolated static let maximumSnapshotBytes = 32 * 1_024 * 1_024
    nonisolated enum Failure: Error, LocalizedError, Equatable {
        case busy, backup, liveJournal, changed, schema, database, checkpoint, noText
        var errorDescription: String? {
            switch self {
            case .busy: "A Notes import is still settling. Stop or wait for it before importing again."
            case .backup: "Choose a standalone Apple Notes database backup, up to 32 MiB, outside system and Library folders."
            case .liveJournal: "This database has a live journal. Choose a complete standalone backup; Relay did not read the live Notes store."
            case .changed: "The chosen Notes backup changed during import. No new snapshot was published."
            case .schema: "This Notes backup schema is unsupported. No note text was imported."
            case .database: "The bounded Notes backup could not be read completely. No new snapshot was published."
            case .checkpoint: "Notes import progress could not be saved or validated. The previous captured snapshot was kept; import the same backup to resume."
            case .noText: "No eligible plain-text notes were available in this backup. Protected, deleted, unavailable and unsupported content was not imported."
            }
        }
    }
    private let executorQueue = DispatchSerialQueue(label: "relay.notes-database-ingestion")
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }
    private let reader = Reader()
    private let checkpointRoot: URL
    private let checkpointObserver: NotesImportCheckpoint.Observer?
    private var active: Task<NativePersonalSourceBatch, Error>?
    private var operation: UUID?
    private var generation = 0
    private var forgetting = false

    init(checkpointRoot: URL = URL.applicationSupportDirectory.appending(path: "Relay/notes-import-v1", directoryHint: .isDirectory),
         checkpointObserver: NotesImportCheckpoint.Observer? = nil) {
        self.checkpointRoot = checkpointRoot; self.checkpointObserver = checkpointObserver
    }

    func importBackup(_ selected: URL) async throws -> NativePersonalSourceBatch {
        guard active == nil, !forgetting else { throw Failure.busy }
        try Task.checkCancellation()
        let id = UUID(), expected = generation, root = checkpointRoot, observer = checkpointObserver, reader = self.reader
        let task = Task { try await reader.read(selected, checkpointRoot: root, checkpointObserver: observer) }
        active = task; operation = id
        defer { if operation == id { active = nil; operation = nil } }
        let result: NativePersonalSourceBatch
        do { result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch {
            try Task.checkCancellation()
            guard expected == generation else { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            // Foundation/SQLite/parser details never become source UI text.
            throw Failure.database
        }
        try Task.checkCancellation(); guard expected == generation else { throw CancellationError() }
        try result.notesBackup?.validateCurrent()
        return result
    }

    func forget() async throws {
        guard !forgetting else { throw Failure.busy }
        forgetting = true; generation += 1; active?.cancel()
        defer { forgetting = false }
        _ = await active?.result
        do { try await reader.removeCheckpoints(checkpointRoot) }
        catch { throw Failure.checkpoint }
    }

    nonisolated static func requireStandalone(_ url: URL) throws {
        for suffix in ["-wal", "-journal", "-shm"] {
            var value = stat()
            if (url.path + suffix).withCString({ lstat($0, &value) }) == 0 { throw Failure.liveJournal }
            guard errno == ENOENT else { throw Failure.backup }
        }
    }

    nonisolated private static func readSync(_ selected: URL, checkpointRoot: URL,
        checkpointObserver: NotesImportCheckpoint.Observer?) throws -> NativePersonalSourceBatch {
        try Task.checkCancellation()
        guard selected.isFileURL, ["sqlite", "sqlite3", "db"].contains(selected.pathExtension.lowercased()) else { throw Failure.backup }
        let canonical = try ToolPolicy.canonicalURL(selected.path)
        let forbidden = ["/System", "/Library", NSHomeDirectory() + "/Library"]
        guard !forbidden.contains(where: { canonical.path == $0 || canonical.path.hasPrefix($0 + "/") }) else { throw Failure.backup }
        try requireStandalone(canonical)
        let snapshot: LocalStateFile.Snapshot
        do { snapshot = try LocalStateFile.snapshot(selected, maximumBytes: maximumSnapshotBytes) }
        catch { throw Failure.backup }
        guard !snapshot.data.isEmpty else { throw Failure.backup }
        let source = NotesBackupIdentity(selected: selected, canonical: canonical, snapshot: snapshot)
        try source.validateCurrent()

        // SQLite consumes these exact descriptor-read bytes in a private owned
        // temporary copy, never a later reread or an implicit WAL sidecar.
        // SQLite no-follow also rejects /var's intermediate symlink. Foundation
        // resolves this alias back to /var, so use its actual POSIX physical root.
        guard let physicalPath = FileManager.default.temporaryDirectory.path.withCString({ realpath($0, nil) }) else {
            throw Failure.database
        }
        let physicalRoot = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
        free(physicalPath)
        let folder = physicalRoot.appending(path: "relay-notes-import-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appending(path: "snapshot.sqlite")
        try LocalPrivateFileWriter.write(data: snapshot.data, to: copy, maximumBytes: maximumSnapshotBytes, createOnly: true)
        var database: OpaquePointer?
        let code = sqlite3_open_v2(copy.absoluteString + "?mode=ro&immutable=1", &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let database { sqlite3_close(database) } }
        guard code == SQLITE_OK, let database, sqlite3_db_readonly(database, "main") == 1 else { throw Failure.database }
        sqlite3_busy_timeout(database, 100)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Int32(NotesBodyDecoder.maximumCompressedBytes + 16_384))
        sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 8_192)
        // Core Data's Notes object table is wide; bound its actual schema
        // independently of the eight columns selected for each note.
        sqlite3_limit(database, SQLITE_LIMIT_COLUMN, 512)
        guard sqlite3_exec(database, "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; PRAGMA mmap_size=0; PRAGMA cache_size=-2048;", nil, nil, nil) == SQLITE_OK else { throw Failure.database }
        let budget = SQLBudget()
        sqlite3_progress_handler(database, 1_000, { raw in
            guard let raw else { return 1 }
            let budget = Unmanaged<SQLBudget>.fromOpaque(raw).takeUnretainedValue()
            return Task<Never, Never>.isCancelled || ContinuousClock.now >= budget.deadline ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil); withExtendedLifetime(budget) {} }
        let columns = try tableColumns(database, table: "ZICCLOUDSYNCINGOBJECT")
        let dataColumns = try tableColumns(database, table: "ZICNOTEDATA")
        guard columns.isSuperset(of: ["Z_PK", "ZIDENTIFIER", "ZTITLE1", "ZTITLE2", "ZFOLDER", "ZNOTEDATA", "ZISPASSWORDPROTECTED", "ZMARKEDFORDELETION"]),
              dataColumns.isSuperset(of: ["Z_PK", "ZDATA"]) else { throw Failure.schema }
        let creation = ["ZCREATIONDATE3", "ZCREATIONDATE2", "ZCREATIONDATE1", "ZCREATIONDATE"].filter { columns.contains($0) }
        guard !creation.isEmpty else { throw Failure.schema }
        let created = creation.count == 1 ? "o." + creation[0] : "COALESCE(" + creation.map { "o." + $0 }.joined(separator: ",") + ")"
        let modification = ["ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"].first { columns.contains($0) }.map { "o." + $0 } ?? "NULL"
        let eligible = "(o.ZISPASSWORDPROTECTED IS NULL OR (typeof(o.ZISPASSWORDPROTECTED)='integer' AND o.ZISPASSWORDPROTECTED=0)) AND (o.ZMARKEDFORDELETION IS NULL OR (typeof(o.ZMARKEDFORDELETION)='integer' AND o.ZMARKEDFORDELETION=0))"
        var coverage = NotesImportCoverage()
        let excluded = try statement(database, "SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT o WHERE o.ZNOTEDATA IS NOT NULL AND NOT (" + eligible + ")")
        defer { sqlite3_finalize(excluded) }
        guard sqlite3_step(excluded) == SQLITE_ROW else { throw Failure.database }
        coverage.excluded = Int(sqlite3_column_int64(excluded, 0))
        let sql = "SELECT o.ZIDENTIFIER,o.ZTITLE1," + created + ",f.ZTITLE2,length(d.ZDATA),CASE WHEN length(d.ZDATA)<=1048576 THEN d.ZDATA ELSE NULL END," + modification
            + " FROM ZICCLOUDSYNCINGOBJECT o LEFT JOIN ZICNOTEDATA d ON d.Z_PK=o.ZNOTEDATA LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK=o.ZFOLDER WHERE o.ZNOTEDATA IS NOT NULL AND " + eligible
            + " ORDER BY " + created + " DESC,o.ZIDENTIFIER COLLATE BINARY,o.Z_PK LIMIT 1001"
        let rows = try statement(database, sql); defer { sqlite3_finalize(rows) }
        let checkpoint = NotesImportCheckpoint(root: checkpointRoot, sourceIdentity: source.checkpointIdentity, observer: checkpointObserver)
        var items: [NativePersonalSourceItem] = [], seen = Set<Data>()
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < budget.deadline else { throw Failure.database }
            let status = sqlite3_step(rows)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw Failure.database }
            if coverage.scanned == maximumNotes { coverage.capped = true; break }
            coverage.scanned += 1
            guard let identifier = try text(rows, 0, maximum: 512), !identifier.isEmpty,
                  seen.insert(Data(identifier.utf8)).inserted,
                  [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(rows, 2)) else { throw Failure.schema }
            let date = sqlite3_column_double(rows, 2)
            guard date.isFinite, (-978_307_200...20_000_000_000).contains(date) else { throw Failure.schema }
            let title = try text(rows, 1, maximum: 1_024), folderName = try text(rows, 3, maximum: 1_024)
            let rawSize = sqlite3_column_type(rows, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(rows, 4)
            let blob: Data?
            if let rawSize, rawSize >= 0, rawSize <= Int64(NotesBodyDecoder.maximumCompressedBytes) {
                guard sqlite3_column_type(rows, 5) == SQLITE_BLOB,
                      Int64(sqlite3_column_bytes(rows, 5)) == rawSize else { throw Failure.schema }
                if rawSize == 0 { blob = Data() }
                else {
                    guard let bytes = sqlite3_column_blob(rows, 5) else { throw Failure.database }
                    blob = Data(bytes: bytes, count: Int(rawSize))
                }
            } else { blob = nil }
            let key = NotesImportCheckpoint.Key(noteID: identifier, created: date,
                blobDigest: blob.map(NotesImportCheckpoint.digest) ?? (rawSize == nil ? "missing" : "oversized"))
            let value: NotesImportCheckpoint.Value
            do {
                if let saved = try checkpoint.load(key) { value = saved; coverage.resumed += 1 }
                else if rawSize == nil { value = try checkpoint.commit(key: key, disposition: .undownloaded) }
                else if blob == nil { value = try checkpoint.commit(key: key, disposition: .oversized) }
                else {
                    let decoded: NotesBodyDecoder.Text?
                    do { decoded = try NotesBodyDecoder.decode(blob!) }
                    catch is CancellationError { throw CancellationError() }
                    catch is NotesBodyDecoder.Failure { decoded = nil }
                    if let decoded {
                        value = try checkpoint.commit(key: key,
                            disposition: decoded.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .decoded, text: decoded)
                    } else { value = try checkpoint.commit(key: key, disposition: .malformed) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { throw Failure.checkpoint }
            switch value.disposition {
            case .undownloaded: coverage.undownloaded += 1
            case .oversized: coverage.oversized += 1
            case .malformed: coverage.malformed += 1
            case .empty: coverage.blank += 1
            case .decoded:
                guard let body = value.text else { throw Failure.checkpoint }
                let updated: Date?
                if sqlite3_column_type(rows, 6) == SQLITE_NULL { updated = nil }
                else {
                    guard [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(rows, 6)),
                          sqlite3_column_double(rows, 6).isFinite,
                          (-978_307_200...20_000_000_000).contains(sqlite3_column_double(rows, 6)) else { throw Failure.schema }
                    updated = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(rows, 6))
                }
                items.append(NativePersonalSourceItem(id: "notes:" + NotesImportCheckpoint.digest(Data((source.checkpointIdentity + ":" + identifier).utf8)),
                    title: title?.isEmpty == false ? title! : NativePersonalSources.bounded(String(body.prefix(80)), maximumBytes: 256),
                    sender: nil, text: body, textLimited: value.limited,
                    notesAttribution: .init(noteID: identifier, folder: folderName, createdAt: Date(timeIntervalSinceReferenceDate: date), updatedAt: updated)))
            }
        }
        try source.validateCurrent()
        // Full current byte proof, not a metadata-only reuse of a previous path.
        guard NotesImportCheckpoint.digest(try LocalStateFile.read(canonical, maximumBytes: maximumSnapshotBytes)) == source.sourceDigest else { throw Failure.changed }
        try source.validateCurrent(); try Task.checkCancellation()
        guard !items.isEmpty else { throw Failure.noText }
        // No private temporary pathname survives a successful publication.
        // The read-only handle is closed by defer before this task returns.
        try FileManager.default.removeItem(at: folder)
        return NativePersonalSourceBatch(items: items, skipped: coverage.excluded + coverage.malformed + coverage.undownloaded + coverage.oversized + coverage.blank,
            scope: nil, notesBackup: source, notesImport: coverage)
    }

    nonisolated private final class SQLBudget { let deadline = ContinuousClock.now.advanced(by: .seconds(30)) }
    nonisolated private static func statement(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var row: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &row, nil) == SQLITE_OK, let row else {
            if let row { sqlite3_finalize(row) }; throw Failure.schema
        }
        return row
    }
    nonisolated private static func tableColumns(_ database: OpaquePointer, table: String) throws -> Set<String> {
        // Names come only from the two fixed call sites, never a DB string.
        guard ["ZICCLOUDSYNCINGOBJECT", "ZICNOTEDATA"].contains(table) else { throw Failure.schema }
        let ordinary = try statement(database, "SELECT sql FROM sqlite_master WHERE type='table' AND name='" + table + "'")
        defer { sqlite3_finalize(ordinary) }
        guard sqlite3_step(ordinary) == SQLITE_ROW,
              try text(ordinary, 0, maximum: 32_768)?.uppercased().hasPrefix("CREATE TABLE") == true else { throw Failure.schema }
        let row = try statement(database, "PRAGMA table_info(" + table + ")"); defer { sqlite3_finalize(row) }
        var columns = Set<String>()
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(row)
            if status == SQLITE_DONE { return columns }
            guard status == SQLITE_ROW, columns.count < 512, let name = try text(row, 1, maximum: 128) else { throw Failure.schema }
            columns.insert(name)
        }
    }
    nonisolated private static func text(_ row: OpaquePointer, _ column: Int32, maximum: Int) throws -> String? {
        if sqlite3_column_type(row, column) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(row, column) == SQLITE_TEXT,
              sqlite3_column_bytes(row, column) <= maximum,
              let pointer = sqlite3_column_text(row, column),
              let value = String(bytes: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(row, column))), encoding: .utf8),
              !value.contains("\0") else { throw Failure.schema }
        return value
    }
}

import Foundation
import SQLite3
@testable import Relay

nonisolated enum NotesImportTestData {
    static func varint(_ number: UInt64) -> Data {
        var number = number, bytes = Data()
        while number >= 128 { bytes.append(UInt8(number & 127) | 128); number >>= 7 }
        bytes.append(UInt8(number)); return bytes
    }
    static func message(_ field: UInt64, _ bytes: Data) -> Data {
        var data = varint(field << 3 | 2); data.append(varint(UInt64(bytes.count))); data.append(bytes); return data
    }
    static func note(_ text: String) throws -> Data { try gzip(message(2, message(3, message(2, Data(text.utf8))))) }
    /// Independent stored-DEFLATE fixture encoder; no Notes/app/SDK data.
    static func gzip(_ bytes: Data, name: String? = nil) throws -> Data {
        var data = Data([0x1f, 0x8b, 8, name == nil ? 0 : 8, 0, 0, 0, 0, 0, 3])
        if let name { data.append(Data(name.utf8)); data.append(0) }
        var offset = 0
        repeat {
            let count = min(65_535, bytes.count - offset)
            data.append(offset + count == bytes.count ? 1 : 0)
            let length = UInt16(count), inverse = ~length
            data.append(UInt8(truncatingIfNeeded: length)); data.append(UInt8(truncatingIfNeeded: length >> 8))
            data.append(UInt8(truncatingIfNeeded: inverse)); data.append(UInt8(truncatingIfNeeded: inverse >> 8))
            data.append(bytes.subdata(in: offset..<offset + count)); offset += count
        } while offset < bytes.count
        for number in [try NotesBodyDecoder.crc32(bytes), UInt32(bytes.count)] {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: number >> shift)) }
        }
        return data
    }
}

nonisolated struct NotesDatabaseFixture: Sendable {
    struct Row: Sendable {
        var id: String
        var title = "Owned note"
        var text: String? = "Synthetic Notes body café 🌍"
        var raw: Data? = nil
        var protected: Int64 = 0
        var deleted: Int64 = 0
    }
    enum Failure: Error { case sqlite }
    let root: URL, database: URL, cache: URL

    @concurrent static func make(_ rows: [Row], creationColumn: String = "ZCREATIONDATE3",
                                omitProtection: Bool = false) async throws -> Self {
        guard ["ZCREATIONDATE3", "ZCREATIONDATE1"].contains(creationColumn) else { throw Failure.sqlite }
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-owned-notes-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let database = root.appending(path: "NotesBackup.sqlite"), cache = root.appending(path: "progress", directoryHint: .isDirectory)
            var db: OpaquePointer?
            guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { throw Failure.sqlite }
            defer { sqlite3_close(db) }
            let protection = omitProtection ? "" : ",ZISPASSWORDPROTECTED INTEGER"
            let schema = "CREATE TABLE ZICCLOUDSYNCINGOBJECT(Z_PK INTEGER PRIMARY KEY,ZIDENTIFIER TEXT,ZTITLE1 TEXT,ZTITLE2 TEXT," + creationColumn
                + " REAL,ZMODIFICATIONDATE1 REAL,ZFOLDER INTEGER,ZNOTEDATA INTEGER,ZMARKEDFORDELETION INTEGER" + protection + ");CREATE TABLE ZICNOTEDATA(Z_PK INTEGER PRIMARY KEY,ZDATA BLOB);"
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK,
                  sqlite3_exec(db, "INSERT INTO ZICCLOUDSYNCINGOBJECT(Z_PK,ZTITLE2) VALUES(50000,'Owned project folder');BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, item) in rows.enumerated() {
                let id = Int64(index + 1)
                var row: OpaquePointer?, body: OpaquePointer?
                let sql = "INSERT INTO ZICCLOUDSYNCINGOBJECT(Z_PK,ZIDENTIFIER,ZTITLE1," + creationColumn + ",ZMODIFICATIONDATE1,ZFOLDER,ZNOTEDATA,ZMARKEDFORDELETION" + (omitProtection ? "" : ",ZISPASSWORDPROTECTED") + ") VALUES(?1,?2,?3,?4,?5,50000,?1,?6" + (omitProtection ? "" : ",?7") + ")"
                guard sqlite3_prepare_v2(db, sql, -1, &row, nil) == SQLITE_OK, let row else { throw Failure.sqlite }
                defer { sqlite3_finalize(row) }
                sqlite3_bind_int64(row, 1, id)
                _ = item.id.withCString { sqlite3_bind_text(row, 2, $0, Int32(item.id.utf8.count), transient) }
                _ = item.title.withCString { sqlite3_bind_text(row, 3, $0, Int32(item.title.utf8.count), transient) }
                sqlite3_bind_double(row, 4, Double(index + 42)); sqlite3_bind_double(row, 5, Double(index + 84))
                sqlite3_bind_int64(row, 6, item.deleted)
                if !omitProtection { sqlite3_bind_int64(row, 7, item.protected) }
                guard sqlite3_step(row) == SQLITE_DONE,
                      sqlite3_prepare_v2(db, "INSERT INTO ZICNOTEDATA(Z_PK,ZDATA) VALUES(?1,?2)", -1, &body, nil) == SQLITE_OK, let body else { throw Failure.sqlite }
                defer { sqlite3_finalize(body) }
                sqlite3_bind_int64(body, 1, id)
                let data = try item.raw ?? item.text.map { try NotesImportTestData.note($0) }
                if let data {
                    _ = data.withUnsafeBytes { sqlite3_bind_blob(body, 2, $0.baseAddress, Int32(data.count), transient) }
                } else { sqlite3_bind_null(body, 2) }
                guard sqlite3_step(body) == SQLITE_DONE else { throw Failure.sqlite }
            }
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite }
            return Self(root: root, database: database, cache: cache)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    @concurrent func remove() async { try? FileManager.default.removeItem(at: root) }
    @concurrent func checkpointFiles() async throws -> [URL] {
        guard let entries = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
    }
    @concurrent func appendUnparsedByte() async throws {
        let file = try FileHandle(forWritingTo: database); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: Data([0]))
    }
    @concurrent func replaceFirstBody(_ text: String) async throws {
        var db: OpaquePointer?, row: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { throw Failure.sqlite }
        defer { sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, "UPDATE ZICNOTEDATA SET ZDATA=?1 WHERE Z_PK=1", -1, &row, nil) == SQLITE_OK, let row else { throw Failure.sqlite }
        defer { sqlite3_finalize(row) }
        let data = try NotesImportTestData.note(text), transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(row, 1, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(row) == SQLITE_DONE else { throw Failure.sqlite }
    }
}

nonisolated final class NotesImportGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var armed = true, arrived = false
    var entered: Bool { lock.withLock { arrived } }
    func observe(_ event: NotesImportCheckpoint.Event) {
        guard case .didCommit = event else { return }
        let block = lock.withLock { () -> Bool in
            guard armed else { return false }; armed = false; arrived = true; return true
        }
        if block { semaphore.wait() }
    }
    func release() { semaphore.signal() }
}

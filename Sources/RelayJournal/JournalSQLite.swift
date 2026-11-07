import Foundation
import SQLite3

enum SQLValue: Equatable { case integer(Int64), text(String), blob(Data), null
    var integer: Int64? { if case let .integer(value) = self { value } else { nil } }
    var data: Data? { if case let .blob(value) = self { value } else { nil } }
    var string: String? { if case let .text(value) = self { value } else { nil } }
}
private final class SQLBudget {
    let end: UInt64
    let honorCancellation: Bool
    init(milliseconds: UInt64, honorCancellation: Bool) { end = DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000; self.honorCancellation = honorCancellation }
}
/// Synchronous, actor-confined handle. No unchecked Sendable conformance or shared statement.
final class JournalSQLite {
    private var handle: OpaquePointer?
    init(path: String, create: Bool = false, busyMilliseconds: Int32 = 250) throws {
        var value: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW | (create ? SQLITE_OPEN_CREATE : 0)
        let code = sqlite3_open_v2(path, &value, flags, nil)
        guard code == SQLITE_OK, let value, sqlite3_db_readonly(value, "main") == 0 else {
            if let value { sqlite3_close(value) }; throw JournalError.sqlite(code)
        }
        handle = value
        sqlite3_extended_result_codes(value, 1)
        sqlite3_busy_timeout(value, max(0, min(1000, busyMilliseconds)))
        // Apple's system module omits load-extension APIs; no caller-supplied SQL is accepted.
        sqlite3_limit(value, SQLITE_LIMIT_LENGTH, 1_048_576)
        sqlite3_limit(value, SQLITE_LIMIT_SQL_LENGTH, 65_536)
        sqlite3_limit(value, SQLITE_LIMIT_COLUMN, 64)
        sqlite3_limit(value, SQLITE_LIMIT_EXPR_DEPTH, 64)
        do { try execute("PRAGMA trusted_schema=OFF"); try execute("PRAGMA foreign_keys=ON") }
        catch { sqlite3_close(value); handle = nil; throw error }
    }
    deinit { if let handle { sqlite3_close_v2(handle) } }
    func close() throws {
        guard let value = handle else { return }
        let code = sqlite3_close(value); guard code == SQLITE_OK else { throw JournalError.sqlite(code) }; handle = nil
    }
    func withBudget<T>(honorCancellation: Bool = true, _ operation: () throws -> T) throws -> T {
        guard let handle else { throw JournalError.closed }
        let budget = SQLBudget(milliseconds: 1000, honorCancellation: honorCancellation)
        let pointer = Unmanaged.passUnretained(budget).toOpaque()
        sqlite3_progress_handler(handle, 1000, { raw in
            guard let raw else { return 1 }
            let budget = Unmanaged<SQLBudget>.fromOpaque(raw).takeUnretainedValue()
            return DispatchTime.now().uptimeNanoseconds >= budget.end || (budget.honorCancellation && Task<Never, Never>.isCancelled) ? 1 : 0
        }, pointer)
        defer { sqlite3_progress_handler(handle, 0, nil, nil); withExtendedLifetime(budget) {} }
        return try operation()
    }
    func execute(_ sql: String, _ arguments: [SQLValue] = []) throws { _ = try query(sql, arguments, maximumRows: 1_000) }
    func query(_ sql: String, _ arguments: [SQLValue] = [], maximumRows: Int = 1_000) throws -> [[SQLValue]] {
        guard let handle else { throw JournalError.closed }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { if let statement { sqlite3_finalize(statement) }; throw JournalError.sqlite(prepared) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == arguments.count else { throw JournalError.invalidEvent }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1), code: Int32
            switch argument {
            case let .integer(value): code = sqlite3_bind_int64(statement, index, value)
            case let .text(value): code = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient) }
            case let .blob(data): code = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw JournalError.sqlite(code) }
        }
        var rows: [[SQLValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw JournalError.sqlite(code) }
            guard rows.count < maximumRows else { throw JournalError.tooLarge }
            var row: [SQLValue] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_NULL: row.append(.null)
                case SQLITE_TEXT, SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index)); guard count <= 262_144 else { throw JournalError.tooLarge }
                    let bytes = sqlite3_column_blob(statement, index)
                    guard count == 0 || bytes != nil else { throw JournalError.sqlite(SQLITE_NOMEM) }
                    let data = count == 0 ? Data() : Data(bytes: bytes!, count: count)
                    if sqlite3_column_type(statement, index) == SQLITE_TEXT {
                        guard let value = String(data: data, encoding: .utf8) else { throw JournalError.corrupt }; row.append(.text(value))
                    } else { row.append(.blob(data)) }
                default: throw JournalError.corrupt
                }
            }
            rows.append(row)
        }
        return rows
    }
    func integer(_ sql: String, _ arguments: [SQLValue] = []) throws -> Int64 {
        guard let value = try query(sql, arguments, maximumRows: 1).first?.first?.integer else { throw JournalError.corrupt }; return value
    }
    func text(_ sql: String) throws -> String {
        guard let value = try query(sql, maximumRows: 1).first?.first?.string else { throw JournalError.corrupt }; return value
    }
    var lastSequence: Int64 { handle.map(sqlite3_last_insert_rowid) ?? 0 }
}

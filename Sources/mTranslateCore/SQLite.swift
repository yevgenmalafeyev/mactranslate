import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Sendable {
    case int(Int64), double(Double), text(String), null
}

public struct SQLError: Error, CustomStringConvertible {
    public let description: String
}

/// Minimal SQLite wrapper. Not thread-safe: owned by the Store actor.
final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            throw SQLError(description: "open failed: \(path)")
        }
        // History is the user's own text: readable by the owner only (the -wal/-shm files inherit this),
        // and deleted rows are overwritten rather than left in the file.
        for suffix in ["", "-wal", "-shm"] { chmod(path + suffix, 0o600) }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON; PRAGMA trusted_schema=OFF; PRAGMA cell_size_check=ON;")
    }

    deinit { sqlite3_close_v2(db) }

    var errorMessage: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLError(description: msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int64 {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLError(description: errorMessage) }
        return sqlite3_last_insert_rowid(db)
    }

    func query(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        var rows: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLError(description: errorMessage) }
            var row: [SQLValue] = []
            for i in 0..<sqlite3_column_count(st) {
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(st, i)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(st, i)))
                case SQLITE_NULL: row.append(.null)
                default: row.append(sqlite3_column_text(st, i).map { .text(String(cString: $0)) } ?? .null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    var userVersion: Int {
        (try? query("PRAGMA user_version").first?.first).flatMap { v -> Int? in
            if case .int(let i) = v { return Int(i) }; return nil
        } ?? 0
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw SQLError(description: errorMessage + " in: " + sql) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .double(let v): sqlite3_bind_double(st, idx, v)
            // NUL would cut the stored text short of what was hashed and sent: it is dropped.
            case .text(let v): sqlite3_bind_text(st, idx, v.replacingOccurrences(of: "\0", with: ""), -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }
}

extension SQLValue {
    var string: String? { if case .text(let s) = self { s } else { nil } }
    var int: Int64? { if case .int(let i) = self { i } else { nil } }
    var double: Double? {
        switch self {
        case .double(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }
}

import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Минимальная обёртка над SQLite: только параметризованные запросы.
public enum SQLValue: Equatable, Sendable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    public var string: String? { if case .text(let s) = self { return s }; return nil }
    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .text(let s): return Int64(s)
        case .null: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .text(let s): return Double(s)
        case .null: return nil
        }
    }
    public var bool: Bool { (int ?? 0) != 0 }
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
}

public extension SQLValue {
    static func of(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    static func of(_ d: Double?) -> SQLValue { d.map { .double($0) } ?? .null }
    static func of(_ b: Bool) -> SQLValue { .int(b ? 1 : 0) }
}

public typealias SQLRow = [String: SQLValue]

public struct SQLiteError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { "SQLite: \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteDB {
    private var handle: OpaquePointer?
    public let path: String

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "не удалось открыть базу"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(message: msg)
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { close() }

    public func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    private var errorMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "база закрыта" }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: "\(errorMessage) — \(sql.prefix(80))")
        }
        for (i, v) in args.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .int(let x): sqlite3_bind_int64(stmt, idx, x)
            case .double(let x): sqlite3_bind_double(stmt, idx, x)
            case .text(let x): sqlite3_bind_text(stmt, idx, x, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    @discardableResult
    public func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(message: errorMessage) }
        return Int(sqlite3_changes(handle))
    }

    public var lastInsertId: Int64 { sqlite3_last_insert_rowid(handle) }

    public func query(_ sql: String, _ args: [SQLValue] = []) throws -> [SQLRow] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: errorMessage) }
            var row: SQLRow = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_NULL: row[name] = .null
                default:
                    if let p = sqlite3_column_text(stmt, c) { row[name] = .text(String(cString: p)) } else { row[name] = .null }
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func scalar(_ sql: String, _ args: [SQLValue] = []) throws -> SQLValue {
        try query(sql, args).first?.values.first ?? .null
    }

    public func tableExists(_ name: String) throws -> Bool {
        try !query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(name)]).isEmpty
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

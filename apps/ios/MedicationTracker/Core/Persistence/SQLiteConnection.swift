import Foundation
import SQLite3

enum SQLiteError: Error {
    case failed(String)
}

enum SQLiteValue: Sendable, Equatable {
    case text(String)
    case int(Int64)
    case double(Double)
    case blob(Data)
    case null
}

/// Envoltura mínima de SQLite. Sólo `LocalStore` la usa y serializa su acceso.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw SQLiteError.failed("open")
        }
        try execute("PRAGMA journal_mode=WAL")
        // FULL sincroniza cada commit: una declaración aceptada por la cola sobrevive a un cierre abrupto.
        try execute("PRAGMA synchronous=FULL")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        _ = try query(sql, values)
    }

    @discardableResult
    func query(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.failed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .text(text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let .int(number): sqlite3_bind_int64(statement, index, number)
            case let .double(number): sqlite3_bind_double(statement, index, number)
            case let .blob(data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        var rows: [[String: SQLiteValue]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row: [String: SQLiteValue] = [:]
                for column in 0 ..< sqlite3_column_count(statement) {
                    row[String(cString: sqlite3_column_name(statement, column))] = value(of: statement, column)
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                throw SQLiteError.failed(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func transaction<Output>(_ work: () throws -> Output) throws -> Output {
        try execute("BEGIN IMMEDIATE")
        do {
            let output = try work()
            try execute("COMMIT")
            return output
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func value(of statement: OpaquePointer?, _ column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }
}

extension [String: SQLiteValue] {
    func text(_ key: String) -> String? {
        if case let .text(value)? = self[key] { return value }
        return nil
    }

    func int(_ key: String) -> Int? {
        if case let .int(value)? = self[key] { return Int(value) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if case let .double(value)? = self[key] { return value }
        return nil
    }

    func blob(_ key: String) -> Data? {
        if case let .blob(value)? = self[key] { return value }
        return nil
    }
}

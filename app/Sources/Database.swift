// mel.db through SQLite's C API, which ships with macOS. ./mel creates and migrates the database (db/*.sql);
// the app reads and edits it while a recording writes to it, which WAL mode allows.
import Foundation
import SQLite3

typealias Row = [String: Any]

final class Database {
    static let shared = Database(path: dataDir.appendingPathComponent("mel.db").path)

    private var db: OpaquePointer?
    private var dataVersion: Int64 = -1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self) // SQLite copies bound values

    init(path: String) {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            NSLog("Mel: can't open \(path): \(String(cString: sqlite3_errmsg(db)))")
        }
        execute("PRAGMA foreign_keys = ON")
        execute("PRAGMA busy_timeout = 5000")
    }

    /// Rows as column name → Int64, Double, String or Data; NULL columns are left out.
    func query(_ sql: String, _ args: Any?...) -> [Row] {
        var rows: [Row] = []
        run(sql, args) { statement in
            var row = Row()
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, i))
                case SQLITE_BLOB: row[name] = Data(bytes: sqlite3_column_blob(statement, i), count: Int(sqlite3_column_bytes(statement, i)))
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Runs a statement and returns the id of the row it inserted, if any.
    @discardableResult
    func execute(_ sql: String, _ args: Any?...) -> Int64 {
        run(sql, args) { _ in }
        return sqlite3_last_insert_rowid(db)
    }

    func transaction(_ body: () -> Void) {
        execute("BEGIN IMMEDIATE")
        body()
        execute("COMMIT")
    }

    /// True once after another connection (a recording, a re-transcription) committed something.
    func changed() -> Bool {
        let version = query("PRAGMA data_version").first?["data_version"] as? Int64 ?? 0
        defer { dataVersion = version }
        return version != dataVersion
    }

    func setting(_ key: String) -> String? {
        query("SELECT value FROM settings WHERE key = ?", key).first?["value"] as? String
    }

    func setSetting(_ key: String, _ value: String) {
        execute("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", key, value)
    }

    private func run(_ sql: String, _ args: [Any?], row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            NSLog("Mel: SQL error \(String(cString: sqlite3_errmsg(db))) in \(sql)")
            return
        }
        defer { sqlite3_finalize(statement) }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as String: sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case let value as Data: _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), Self.transient) }
            default: sqlite3_bind_null(statement, index)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return
            default:
                NSLog("Mel: SQL error \(String(cString: sqlite3_errmsg(db))) in \(sql)")
                return
            }
        }
    }
}

/// Voiceprints are stored as unit-length float32 arrays (`pack` in client/mel.py).
func floats(_ blob: Data) -> [Float] {
    blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

func blob(_ vector: [Float]) -> Data {
    vector.withUnsafeBufferPointer { Data(buffer: $0) }
}

func unit(_ v: [Float]) -> [Float] {
    let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
    return norm > 0 ? v.map { $0 / norm } : v
}

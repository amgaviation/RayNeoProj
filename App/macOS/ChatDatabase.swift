import Foundation
import SQLite3
import ReminderCore

/// Read-only access to the Messages database, used to confirm delivery, notice
/// failures and pick up STOP replies. Needs Full Disk Access; without it `open()`
/// returns nil and the relay simply sends without those extras.
final class ChatDatabase {
    struct Outgoing {
        let guid: String
        let date: Date
        let isDelivered: Bool
        let deliveredAt: Date?
        let error: Int
        let service: String
    }

    struct Incoming {
        let rowID: Int64
        let handle: String
        let text: String
        let date: Date
        let service: String
    }

    static var path: String {
        NSHomeDirectory() + "/Library/Messages/chat.db"
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens the database, or nil when it's unreadable (usually no Full Disk Access).
    static func open() -> ChatDatabase? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 2_000)
        let database = ChatDatabase(handle: handle)
        // Opening can succeed without access; the first read is the real test.
        guard database.scalarInt("SELECT COUNT(*) FROM (SELECT ROWID FROM message LIMIT 1)") != nil else {
            return nil
        }
        return database
    }

    private init(handle: OpaquePointer) {
        db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    /// Outgoing messages to `handle` since `since`, oldest first.
    func outgoing(to handle: String, since: Date, limit: Int = 5) -> [Outgoing] {
        let sql = """
            SELECT m.guid, m.date, m.is_delivered, m.date_delivered, m.error, m.service
            FROM message m JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.is_from_me = 1 AND lower(h.id) = lower(?1) AND m.date >= ?2
            ORDER BY m.date ASC LIMIT ?3
            """
        return query(sql, bind: { statement in
            sqlite3_bind_text(statement, 1, handle, -1, Self.transient)
            sqlite3_bind_int64(statement, 2, AppleTime.chatDBValue(from: since))
            sqlite3_bind_int(statement, 3, Int32(limit))
        }, row: Self.outgoingRow)
    }

    /// Current state of one outgoing message.
    func outgoing(guid: String) -> Outgoing? {
        let sql = """
            SELECT m.guid, m.date, m.is_delivered, m.date_delivered, m.error, m.service
            FROM message m WHERE m.guid = ?1 LIMIT 1
            """
        return query(sql, bind: { statement in
            sqlite3_bind_text(statement, 1, guid, -1, Self.transient)
        }, row: Self.outgoingRow).first
    }

    /// Incoming messages after `rowID`, oldest first.
    func incoming(afterRowID rowID: Int64, limit: Int = 500) -> [Incoming] {
        let sql = """
            SELECT m.ROWID, h.id, m.text, m.attributedBody, m.date, m.service
            FROM message m JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.is_from_me = 0 AND m.ROWID > ?1
            ORDER BY m.ROWID ASC LIMIT ?2
            """
        return query(sql, bind: { statement in
            sqlite3_bind_int64(statement, 1, rowID)
            sqlite3_bind_int(statement, 2, Int32(limit))
        }, row: { statement in
            let rowID = sqlite3_column_int64(statement, 0)
            let handle = Self.text(statement, 1) ?? ""
            var body = Self.text(statement, 2) ?? ""
            if body.isEmpty, let blob = Self.blob(statement, 3) {
                body = TypedStreamText.extract(from: blob) ?? ""
            }
            let date = AppleTime.date(fromChatDB: sqlite3_column_int64(statement, 4))
            let service = Self.text(statement, 5) ?? ""
            return Incoming(rowID: rowID, handle: handle, text: body, date: date, service: service)
        })
    }

    func maxMessageRowID() -> Int64 {
        Int64(scalarInt("SELECT IFNULL(MAX(ROWID), 0) FROM message") ?? 0)
    }

    // MARK: Plumbing

    private static func outgoingRow(_ statement: OpaquePointer) -> Outgoing {
        let deliveredValue = sqlite3_column_int64(statement, 3)
        return Outgoing(
            guid: text(statement, 0) ?? "",
            date: AppleTime.date(fromChatDB: sqlite3_column_int64(statement, 1)),
            isDelivered: sqlite3_column_int(statement, 2) != 0,
            deliveredAt: deliveredValue > 0 ? AppleTime.date(fromChatDB: deliveredValue) : nil,
            error: Int(sqlite3_column_int(statement, 4)),
            service: text(statement, 5) ?? ""
        )
    }

    private func query<T>(_ sql: String, bind: (OpaquePointer) -> Void, row: (OpaquePointer) -> T) -> [T] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(row(statement))
        }
        return results
    }

    private func scalarInt(_ sql: String) -> Int? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: count)
    }
}

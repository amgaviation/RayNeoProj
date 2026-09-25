import Foundation
import SQLite3
import XCTest
import ReminderCore

/// Runs the relay's Messages-database queries against a small database with the
/// same tables and columns as ~/Library/Messages/chat.db.
final class ChatDatabaseTests: XCTestCase {
    private var path = ""
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "chat-\(UUID().uuidString).db"
        try execute("""
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, service TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, text TEXT, attributedBody BLOB,
                handle_id INTEGER DEFAULT 0, service TEXT, error INTEGER DEFAULT 0, date INTEGER,
                date_delivered INTEGER DEFAULT 0, is_delivered INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0
            );
            INSERT INTO handle (id, service) VALUES ('+15551230001', 'iMessage');
            INSERT INTO handle (id, service) VALUES ('Pat@Example.com', 'iMessage');
            """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testOpenFailsWhenTheFileIsMissing() {
        XCTAssertNil(ChatDatabase.open(path: NSTemporaryDirectory() + "missing-\(UUID().uuidString)/chat.db"))
    }

    func testOutgoingMatchesHandlesCaseInsensitively() throws {
        let sent = Date(timeIntervalSince1970: 1_790_000_000)
        try insert(guid: "G1", handleID: 2, fromMe: true, date: sent, delivered: sent.addingTimeInterval(3), service: "iMessage")
        try insert(guid: "G0", handleID: 2, fromMe: true, date: sent.addingTimeInterval(-600), service: "iMessage")

        let database = try XCTUnwrap(ChatDatabase.open(path: path))
        let rows = database.outgoing(to: "pat@example.com", since: sent.addingTimeInterval(-2))
        XCTAssertEqual(rows.map(\.guid), ["G1"])
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.isDelivered)
        XCTAssertEqual(row.error, 0)
        XCTAssertEqual(row.service, "iMessage")
        XCTAssertEqual(row.date.timeIntervalSince1970, sent.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.deliveredAt).timeIntervalSince1970, sent.timeIntervalSince1970 + 3, accuracy: 0.001)
    }

    func testOutgoingByGUIDReportsErrors() throws {
        let sent = Date(timeIntervalSince1970: 1_790_000_000)
        try insert(guid: "FAIL", handleID: 1, fromMe: true, date: sent, error: 22, service: "iMessage")
        let database = try XCTUnwrap(ChatDatabase.open(path: path))
        let row = try XCTUnwrap(database.outgoing(guid: "FAIL"))
        XCTAssertEqual(row.error, 22)
        XCTAssertFalse(row.isDelivered)
        XCTAssertNil(row.deliveredAt)
        XCTAssertNil(database.outgoing(guid: "nope"))
    }

    func testIncomingDecodesAttributedBodyAndSkipsOwnMessages() throws {
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        try insert(guid: "OUT", text: "Reminder text", handleID: 1, fromMe: true, date: when, service: "iMessage")
        try insert(guid: "IN1", text: nil, body: typedStream("STOP"), handleID: 1, fromMe: false, date: when.addingTimeInterval(60), service: "SMS")
        try insert(guid: "IN2", text: "Thanks!", handleID: 2, fromMe: false, date: when.addingTimeInterval(120), service: "iMessage")

        let database = try XCTUnwrap(ChatDatabase.open(path: path))
        let replies = database.incoming(afterRowID: 0)
        XCTAssertEqual(replies.map(\.text), ["STOP", "Thanks!"])
        XCTAssertEqual(replies.first?.handle, "+15551230001")
        XCTAssertEqual(replies.first?.service, "SMS")
        XCTAssertEqual(OptOutDetector.classify(replies[0].text), .optOut)

        let later = database.incoming(afterRowID: replies[0].rowID)
        XCTAssertEqual(later.map(\.text), ["Thanks!"])
        XCTAssertEqual(database.maxMessageRowID(), replies[1].rowID)
    }

    // MARK: Helpers

    private func execute(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw TestError.sqlite("open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func insert(
        guid: String,
        text: String? = "",
        body: [UInt8]? = nil,
        handleID: Int,
        fromMe: Bool,
        date: Date,
        delivered: Date? = nil,
        error: Int = 0,
        service: String
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw TestError.sqlite("open") }
        defer { sqlite3_close(db) }
        let sql = """
            INSERT INTO message (guid, text, attributedBody, handle_id, service, error, date, date_delivered, is_delivered, is_from_me)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TestError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, guid, -1, Self.transient)
        if let text {
            sqlite3_bind_text(statement, 2, text, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        if let body {
            _ = body.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(buffer.count), Self.transient)
            }
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_int64(statement, 4, Int64(handleID))
        sqlite3_bind_text(statement, 5, service, -1, Self.transient)
        sqlite3_bind_int64(statement, 6, Int64(error))
        sqlite3_bind_int64(statement, 7, AppleTime.chatDBValue(from: date))
        sqlite3_bind_int64(statement, 8, delivered.map(AppleTime.chatDBValue(from:)) ?? 0)
        sqlite3_bind_int64(statement, 9, delivered == nil ? 0 : 1)
        sqlite3_bind_int64(statement, 10, fromMe ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TestError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// A minimal archived NSAttributedString, laid out like real chat.db rows.
    private func typedStream(_ text: String) -> [UInt8] {
        let utf8 = Array(text.utf8)
        var bytes: [UInt8] = Array("\u{04}\u{0B}streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
        bytes += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84]
        bytes += Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84]
        bytes += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B, UInt8(utf8.count)]
        bytes += utf8
        bytes += [0x86, 0x84, 0x02, 0x69, 0x49, 0x01]
        return bytes
    }

    private enum TestError: Error {
        case sqlite(String)
    }
}

/// Compiles the relay's AppleScript against the real Messages scripting
/// dictionary, which catches wrong class or property names (for example
/// `account`, `participant`, `service type`) without sending anything.
final class MessagesScriptTests: XCTestCase {
    func testSendScriptCompiles() {
        assertCompiles(MessagesSender.sendScript)
    }

    func testPermissionProbeCompiles() {
        assertCompiles(MessagesSender.permissionProbeScript)
    }

    private func assertCompiles(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        guard let script = NSAppleScript(source: lines.joined(separator: "\n")) else {
            XCTFail("Could not create the script", file: file, line: line)
            return
        }
        var error: NSDictionary?
        let compiled = script.compileAndReturnError(&error)
        XCTAssertTrue(compiled, "AppleScript failed to compile: \(String(describing: error))", file: file, line: line)
    }
}

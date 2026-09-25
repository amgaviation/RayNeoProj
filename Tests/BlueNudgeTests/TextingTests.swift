import Foundation
import XCTest
import ReminderCore

/// Records requests and replies with canned responses, so the texting client
/// can be tested without a server.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBody = data
        }
        Self.requests.append(recorded)
        let (status, body) = Self.responses.isEmpty ? (200, "{}") : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TextingAPITests: XCTestCase {
    private let config = TextingConfig(projectURL: URL(string: "https://ref.supabase.co")!, publishableKey: "sb_publishable_test")
    private let userID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func api() -> TextingAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return TextingAPI(config: config, session: URLSession(configuration: configuration))
    }

    private func session() -> TextingSession {
        TextingSession(accessToken: "access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3_600), userID: userID, phone: "+15125550142")
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    override func setUp() {
        StubProtocol.responses = []
        StubProtocol.requests = []
    }

    func testSignInFlow() async throws {
        StubProtocol.responses = [
            (200, "{}"),
            (200, """
            {"access_token":"a1","refresh_token":"r1","expires_at":1790000000,"expires_in":3600,
             "user":{"id":"11111111-2222-3333-4444-555555555555","phone":"15125550142"}}
            """),
        ]
        try await api().sendCode(to: "+15125550142")
        let signedIn = try await api().verify(phone: "+15125550142", code: "123456")

        let otp = StubProtocol.requests[0]
        XCTAssertEqual(otp.url?.absoluteString, "https://ref.supabase.co/auth/v1/otp")
        XCTAssertEqual(otp.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertNil(otp.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try json(otp)["phone"] as? String, "+15125550142")

        let verify = StubProtocol.requests[1]
        XCTAssertEqual(verify.url?.path, "/auth/v1/verify")
        XCTAssertEqual(try json(verify)["type"] as? String, "sms")
        XCTAssertEqual(try json(verify)["token"] as? String, "123456")

        XCTAssertEqual(signedIn.accessToken, "a1")
        XCTAssertEqual(signedIn.userID, userID)
        XCTAssertEqual(signedIn.phone, "+15125550142")
        XCTAssertEqual(signedIn.expiresAt.timeIntervalSince1970, 1_790_000_000)
    }

    func testRefreshUsesTheRefreshToken() async throws {
        StubProtocol.responses = [(200, #"{"access_token":"a2","refresh_token":"r2","expires_in":3600,"user":{"id":"11111111-2222-3333-4444-555555555555","phone":"+15125550142"}}"#)]
        let refreshed = try await api().refresh(session())
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://ref.supabase.co/auth/v1/token?grant_type=refresh_token")
        XCTAssertEqual(try json(request)["refresh_token"] as? String, "refresh")
        XCTAssertEqual(refreshed.refreshToken, "r2")
        XCTAssertFalse(refreshed.needsRefresh())
    }

    func testSyncOutboxSendsTheQueue() async throws {
        StubProtocol.responses = [(200, "2")]
        let fireAt = Date(timeIntervalSince1970: 1_790_000_000)
        let items = [
            OutboxItem(key: "k1", reminderID: userID, title: "Vitamins", body: "Take your vitamins", fireAt: fireAt),
            OutboxItem(key: "k2", reminderID: userID, title: "Water", body: "Drink water", fireAt: fireAt.addingTimeInterval(60)),
        ]
        let count = try await api().syncOutbox(items, timeZone: "America/Chicago", session: session())
        XCTAssertEqual(count, 2)

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/sync_outbox")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
        let body = try json(request)
        XCTAssertEqual(body["p_time_zone"] as? String, "America/Chicago")
        let sent = try XCTUnwrap(body["p_items"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0]["key"] as? String, "k1")
        XCTAssertEqual(sent[0]["reminder_id"] as? String, userID.uuidString)
        XCTAssertEqual(sent[0]["fire_at"] as? String, "2026-09-21T14:13:20Z")
    }

    func testAccountStatusAndRecentTextsDecodePostgresDates() async throws {
        StubProtocol.responses = [
            (200, """
            {"phone":"+15125550142","texts_paused":false,"subscribed":true,
             "entitled_until":"2026-10-25T15:00:00.123456+00:00","product_id":"texts.monthly",
             "sent_this_month":12,"monthly_cap":300,"queued":40}
            """),
            (200, """
            [{"id":7,"title":"Vitamins","body":"Take your vitamins","fire_at":"2026-09-25T13:00:00+00:00",
              "status":"delivered","error":null,"sent_at":"2026-09-25T13:00:02.5+00:00","source":"app"}]
            """),
        ]
        let fetched = try await api().accountStatus(session())
        let status = try XCTUnwrap(fetched)
        XCTAssertTrue(status.subscribed)
        XCTAssertEqual(status.sentThisMonth, 12)
        XCTAssertEqual(status.monthlyCap, 300)
        XCTAssertEqual(try XCTUnwrap(status.entitledUntil).timeIntervalSince1970, 1_792_940_400.123, accuracy: 0.001)

        let texts = try await api().recentTexts(session: session())
        XCTAssertEqual(texts.map(\.id), [7])
        XCTAssertEqual(try XCTUnwrap(texts.first?.sentAt).timeIntervalSince1970, 1_790_341_202.5, accuracy: 0.001)
        let query = try XCTUnwrap(StubProtocol.requests.last?.url?.query)
        XCTAssertTrue(query.contains("order=fire_at.desc"))
    }

    func testErrorsCarryTheServerMessage() async {
        StubProtocol.responses = [(400, #"{"code":"otp_expired","msg":"Token has expired or is invalid"}"#), (401, "{}")]
        do {
            _ = try await api().verify(phone: "+15125550142", code: "000000")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? TextingError, .server("Token has expired or is invalid"))
        }
        do {
            _ = try await api().accountStatus(session())
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? TextingError, .notSignedIn)
        }
    }

    func testSupabaseDates() {
        XCTAssertEqual(SupabaseDate.parse("2026-09-25T13:00:00Z")?.timeIntervalSince1970, 1_790_341_200)
        XCTAssertEqual(SupabaseDate.parse("2026-09-25T13:00:00+00:00")?.timeIntervalSince1970, 1_790_341_200)
        XCTAssertEqual(try XCTUnwrap(SupabaseDate.parse("2026-09-25T13:00:00.987654+00:00")).timeIntervalSince1970, 1_790_341_200.987, accuracy: 0.001)
        XCTAssertNil(SupabaseDate.parse("yesterday"))
    }

    func testOnlyAllowedCountriesAreTexted() {
        XCTAssertTrue(config.allows("+15125550142"))
        XCTAssertFalse(config.allows("+447700900123"))
        var anywhere = config
        anywhere.callingCodes = ["*"]
        XCTAssertTrue(anywhere.allows("+447700900123"))
        var ukToo = config
        ukToo.callingCodes = ["1", "44"]
        XCTAssertTrue(ukToo.allows("+447700900123"))
    }

    func testConfigNeedsHTTPSAndAKey() {
        XCTAssertNil(TextingConfig.fromBundle(Bundle(for: TextingAPITests.self)))
    }
}

final class OutboxPlannerTests: XCTestCase {
    func testOnlyTextRemindersAreQueued() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let schedule = Schedule(frequency: .daily, start: start, timeZoneIdentifier: "UTC")
        let text = PlannerReminder(id: UUID(), title: "Vitamins", template: "Take your vitamins at {time}", schedule: schedule,
                                   recipientIDs: [], method: .sms, isActive: true, activeSince: start.addingTimeInterval(-60))
        let alarm = PlannerReminder(id: UUID(), title: "Meds", template: "Meds", schedule: schedule,
                                    recipientIDs: [], method: .alarm, isActive: true, activeSince: start.addingTimeInterval(-60))
        let paused = PlannerReminder(id: UUID(), title: "Paused", template: "x", schedule: schedule,
                                     recipientIDs: [], method: .sms, isActive: false, activeSince: start)

        let items = OutboxPlanner.items(reminders: [text, alarm, paused], settings: RenderSettings(locale: Locale(identifier: "en_US")),
                                        now: start.addingTimeInterval(-1))
        XCTAssertEqual(items.count, 45)
        XCTAssertTrue(items.allSatisfy { $0.reminderID == text.id })
        XCTAssertEqual(items.first?.fireAt, start)
        XCTAssertEqual(items.first?.body, "Take your vitamins at 2:13 PM")
        XCTAssertEqual(items.first?.key, "\(text.id.uuidString)|sms|1790000000")
        XCTAssertEqual(Set(items.map(\.key)).count, items.count)
    }

    func testLongTextsAreCut() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let reminder = PlannerReminder(id: UUID(), title: "Long", template: String(repeating: "a", count: 900),
                                       schedule: Schedule(frequency: .once, start: start, timeZoneIdentifier: "UTC"),
                                       recipientIDs: [], method: .sms, isActive: true, activeSince: start.addingTimeInterval(-60))
        let items = OutboxPlanner.items(reminders: [reminder], settings: RenderSettings(), now: start.addingTimeInterval(-1))
        XCTAssertEqual(items.first?.body.count, OutboxPlanner.maxLength)
    }
}

@MainActor
final class ActivityEntryTests: XCTestCase {
    func testServerStatuses() {
        XCTAssertEqual(ActivityEntry.status(server: "sending", error: nil), .sending)
        XCTAssertEqual(ActivityEntry.status(server: "sent", error: nil), .sent)
        XCTAssertEqual(ActivityEntry.status(server: "delivered", error: nil), .delivered)
        XCTAssertEqual(ActivityEntry.status(server: "failed", error: "Carrier rejected it."), .failed)
        XCTAssertEqual(ActivityEntry.status(server: "missed", error: nil), .missed)
        XCTAssertEqual(ActivityEntry.status(server: "skipped", error: "Texts are paused."), .optedOut)
        XCTAssertEqual(ActivityEntry.status(server: "skipped", error: "Monthly text limit reached."), .skipped)
    }

    func testMacAndServerTextsAreMergedNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let message = PlannedMessage(
            key: "k", reminderID: UUID(), recipientID: UUID(), occurrence: base, reminderTitle: "Vitamins",
            recipientName: "Me", handle: "+15125550142", service: .auto, text: "Take your vitamins"
        )
        let record = DeliveryRecord(message: message, status: .delivered, channel: .relay, deviceName: "Mac mini")
        record.createdAt = base.addingTimeInterval(60)
        record.serviceUsed = "iMessage"
        let text = RemoteText(id: 7, title: "", body: "Drink water", fireAt: base, status: "skipped",
                              error: "Texts are paused.", sentAt: nil, source: "app")
        let later = RemoteText(id: 8, title: "Call Mom", body: "Call Mom", fireAt: base.addingTimeInterval(3_600),
                               status: "delivered", error: nil, sentAt: base.addingTimeInterval(3_602), source: "app")

        let entries = ActivityEntry.merged(records: [record], texts: [text, later])
        XCTAssertEqual(entries.map(\.id), ["text-8", "record-\(record.id.uuidString)", "text-7"])
        XCTAssertEqual(entries[0].deliveredAt, base.addingTimeInterval(3_602))
        XCTAssertEqual(entries[1].via, "iMessage · Mac mini")
        XCTAssertEqual(entries[2].title, "Reminder")
        XCTAssertEqual(entries[2].status, .optedOut)
        XCTAssertEqual(entries[2].note, "Texts are paused.")
    }
}

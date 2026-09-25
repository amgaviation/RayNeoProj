import Foundation

/// Where BlueNudge's texting backend lives. Read from Info.plist, which gets the
/// values from the SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY build settings;
/// when they're empty, texting is hidden in the app.
struct TextingConfig: Equatable, Sendable {
    let projectURL: URL
    let publishableKey: String
    /// Calling codes the server texts (TEXTING_CALLING_CODES; must match the
    /// backend's SMS_ALLOWED_COUNTRY_CODES). Empty or "*" means any.
    var callingCodes: [String] = ["1"]

    static func fromBundle(_ bundle: Bundle = .main) -> TextingConfig? {
        guard let raw = bundle.object(forInfoDictionaryKey: "BNSupabaseURL") as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil,
              let key = bundle.object(forInfoDictionaryKey: "BNSupabaseKey") as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var config = TextingConfig(projectURL: url, publishableKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
        if let codes = bundle.object(forInfoDictionaryKey: "BNTextingCallingCodes") as? String {
            config.callingCodes = codes.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "") }
                .filter { !$0.isEmpty }
        }
        return config
    }

    /// Whether the server texts `phone` (E.164).
    func allows(_ phone: String) -> Bool {
        guard !callingCodes.isEmpty, !callingCodes.contains("*") else { return true }
        let digits = phone.hasPrefix("+") ? String(phone.dropFirst()) : phone
        return callingCodes.contains { digits.hasPrefix($0) }
    }
}

/// A signed-in texting account. The refresh token is kept in the Keychain.
struct TextingSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: UUID
    var phone: String

    func needsRefresh(now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < 120
    }
}

/// Everything the app shows about the account (`account_status()` on the server).
struct AccountStatus: Decodable, Equatable, Sendable {
    var phone: String
    var textsPaused: Bool
    var subscribed: Bool
    var entitledUntil: Date?
    var productID: String?
    var sentThisMonth: Int
    var monthlyCap: Int?
    var queued: Int

    enum CodingKeys: String, CodingKey {
        case phone
        case textsPaused = "texts_paused"
        case subscribed
        case entitledUntil = "entitled_until"
        case productID = "product_id"
        case sentThisMonth = "sent_this_month"
        case monthlyCap = "monthly_cap"
        case queued
    }
}

/// One upcoming text handed to the server.
struct OutboxItem: Encodable, Equatable, Sendable {
    var key: String
    var reminderID: UUID
    var title: String
    var body: String
    var fireAt: Date

    enum CodingKeys: String, CodingKey {
        case key
        case reminderID = "reminder_id"
        case title
        case body
        case fireAt = "fire_at"
    }
}

/// A text the server sent (or couldn't), for Activity.
struct RemoteText: Decodable, Identifiable, Equatable, Sendable {
    var id: Int
    var title: String
    var body: String
    var fireAt: Date
    var status: String
    var error: String?
    var sentAt: Date?
    var source: String

    enum CodingKeys: String, CodingKey {
        case id, title, body, status, error, source
        case fireAt = "fire_at"
        case sentAt = "sent_at"
    }
}

enum TextingError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Texting isn't set up in this build."
        case .notSignedIn: return "Sign in with your phone number first."
        case .server(let message): return message
        case .network(let message): return message
        }
    }
}

/// Talks to the Supabase backend with plain URLSession: Auth for the phone
/// sign-in, PostgREST for the account's functions, and the Edge Functions.
struct TextingAPI: Sendable {
    let config: TextingConfig
    let session: URLSession

    init(config: TextingConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: Sign-in

    /// Texts a six-digit code to `phone` (E.164).
    func sendCode(to phone: String) async throws {
        _ = try await send("POST", "auth/v1/otp", body: ["phone": phone, "create_user": true] as [String: Any])
    }

    func verify(phone: String, code: String) async throws -> TextingSession {
        let data = try await send("POST", "auth/v1/verify", body: ["type": "sms", "phone": phone, "token": code])
        return try Self.session(from: data)
    }

    func refresh(_ current: TextingSession) async throws -> TextingSession {
        let data = try await send(
            "POST", "auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: ["refresh_token": current.refreshToken]
        )
        return try Self.session(from: data)
    }

    func signOut(_ current: TextingSession) async {
        _ = try? await send("POST", "auth/v1/logout", body: [String: String](), token: current.accessToken)
    }

    // MARK: Account

    func accountStatus(_ current: TextingSession) async throws -> AccountStatus? {
        let data = try await send("POST", "rest/v1/rpc/account_status", body: [String: String](), token: current.accessToken)
        if data.isEmpty || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return nil
        }
        return try Self.decoder.decode(AccountStatus.self, from: data)
    }

    /// Replaces the queued texts with `items`. Returns how many were queued.
    @discardableResult
    func syncOutbox(_ items: [OutboxItem], timeZone: String, session current: TextingSession) async throws -> Int {
        struct Body: Encodable {
            let p_items: [OutboxItem]
            let p_time_zone: String
        }
        let data = try await send(
            "POST", "rest/v1/rpc/sync_outbox",
            encodable: Body(p_items: items, p_time_zone: timeZone), token: current.accessToken
        )
        return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func setPaused(_ paused: Bool, session current: TextingSession) async throws {
        _ = try await send("POST", "rest/v1/rpc/set_texts_paused", body: ["p_paused": paused], token: current.accessToken)
    }

    func recentTexts(limit: Int = 60, session current: TextingSession) async throws -> [RemoteText] {
        let data = try await send("GET", "rest/v1/outbox", query: [
            URLQueryItem(name: "select", value: "id,title,body,fire_at,status,error,sent_at,source"),
            URLQueryItem(name: "status", value: "in.(sending,sent,delivered,failed,missed,skipped)"),
            URLQueryItem(name: "order", value: "fire_at.desc"),
            URLQueryItem(name: "limit", value: String(limit)),
        ], token: current.accessToken)
        return try Self.decoder.decode([RemoteText].self, from: data)
    }

    // MARK: Edge Functions

    /// Asks the server to look the purchase up with Apple. Returns whether texts are unlocked.
    func verifySubscription(transactionID: UInt64, session current: TextingSession) async throws -> Bool {
        let data = try await send(
            "POST", "functions/v1/verify-subscription",
            body: ["transactionId": String(transactionID)], token: current.accessToken
        )
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return result?["subscribed"] as? Bool ?? false
    }

    func deleteAccount(session current: TextingSession) async throws {
        _ = try await send("POST", "functions/v1/delete-account", body: [String: String](), token: current.accessToken)
    }

    // MARK: Plumbing

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data?, token: String?) -> URLRequest {
        var components = URLComponents(url: config.projectURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil, token: String? = nil) async throws -> Data {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await perform(request(method, path, query: query, body: data, token: token))
    }

    private func send<T: Encodable>(_ method: String, _ path: String, encodable: T, token: String?) async throws -> Data {
        try await perform(request(method, path, body: try Self.encoder.encode(encodable), token: token))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TextingError.network("Couldn't reach BlueNudge. Check your connection and try again.")
        }
        guard let http = response as? HTTPURLResponse else { throw TextingError.network("No response from BlueNudge.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw TextingError.notSignedIn }
            throw TextingError.server(Self.errorMessage(from: data) ?? "BlueNudge returned an error (\(http.statusCode)).")
        }
        return data
    }

    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["msg", "error_description", "message", "error"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    static func session(from data: Data) throws -> TextingSession {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String,
              let refresh = object["refresh_token"] as? String,
              let user = object["user"] as? [String: Any],
              let idText = user["id"] as? String, let id = UUID(uuidString: idText)
        else { throw TextingError.server("Unexpected sign-in response.") }
        let expiresAt: Date
        if let at = object["expires_at"] as? Double {
            expiresAt = Date(timeIntervalSince1970: at)
        } else {
            expiresAt = Date().addingTimeInterval(object["expires_in"] as? Double ?? 3_600)
        }
        let rawPhone = user["phone"] as? String ?? ""
        let phone = rawPhone.isEmpty || rawPhone.hasPrefix("+") ? rawPhone : "+" + rawPhone
        return TextingSession(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, userID: id, phone: phone)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = SupabaseDate.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
            }
            return date
        }
        return decoder
    }()
}

/// Postgres timestamps ("2026-09-25T15:00:00.123456+00:00") to Date.
enum SupabaseDate {
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // Keep milliseconds; Foundation doesn't read Postgres' microseconds.
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let fractionEnd = text[dot...].dropFirst().firstIndex { !$0.isNumber } ?? text.endIndex
        let digits = text[text.index(after: dot)..<fractionEnd]
        let millis = String((digits + "000").prefix(3))
        let trimmed = String(text[..<dot]) + "." + millis + String(text[fractionEnd...])
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: trimmed)
    }
}

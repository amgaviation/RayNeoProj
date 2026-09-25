import Foundation
import SwiftData
import ReminderCore

/// The BlueNudge texting account on this iPhone: phone sign-in, what the server
/// knows (subscription, pause, usage) and keeping the server's queue of texts in
/// step with the "Text me" reminders.
@MainActor
final class TextingAccount: ObservableObject {
    static let shared = TextingAccount()

    @Published private(set) var session: TextingSession?
    @Published private(set) var status: AccountStatus?
    @Published private(set) var recentTexts: [RemoteText] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published var codeSentTo: String?
    @Published private(set) var isWorking = false

    let config: TextingConfig?
    private var api: TextingAPI? { config.map { TextingAPI(config: $0) } }
    private static let sessionKey = "session"
    private var syncTask: Task<Void, Never>?

    var isConfigured: Bool { config != nil || DemoMode.isEnabled }
    var isSignedIn: Bool { session != nil }
    var isSubscribed: Bool { status?.subscribed ?? false }
    var textsPaused: Bool { status?.textsPaused ?? false }
    /// True when "Text me" reminders will actually go out.
    var isReady: Bool { isSignedIn && isSubscribed && !textsPaused }

    private init() {
        config = TextingConfig.fromBundle()
        if DemoMode.isEnabled {
            applyDemoState()
        } else if let data = Keychain.data(for: Self.sessionKey) {
            session = try? JSONDecoder().decode(TextingSession.self, from: data)
        }
    }

    // MARK: Sign-in

    func sendCode(to rawPhone: String, countryCode: String) async {
        guard let api else { return fail(TextingError.notConfigured) }
        guard let phone = HandleNormalizer.normalize(rawPhone, defaultCountryCode: countryCode),
              !HandleNormalizer.isEmail(phone) else {
            lastError = "Enter a mobile phone number."
            return
        }
        guard api.config.allows(phone) else {
            lastError = "BlueNudge can't text numbers in that country yet."
            return
        }
        await run {
            try await api.sendCode(to: phone)
            self.codeSentTo = phone
        }
    }

    func verify(code: String) async {
        guard let api, let phone = codeSentTo else { return }
        let digits = code.filter(\.isNumber)
        await run {
            let signedIn = try await api.verify(phone: phone, code: digits)
            self.store(signedIn)
            self.codeSentTo = nil
            await self.refresh()
            await SubscriptionStore.shared.claimCurrentEntitlements()
            // Queue "Text me" reminders made before signing in.
            AppState.shared.dataDidChange()
        }
    }

    func signOut() async {
        if let api, let session { await api.signOut(session) }
        store(nil)
        status = nil
        recentTexts = []
    }

    func deleteAccount() async {
        guard let api else { return }
        await run {
            try await api.deleteAccount(session: try await self.validSession())
            self.store(nil)
            self.status = nil
            self.recentTexts = []
        }
    }

    // MARK: Server state

    func refresh() async {
        guard !DemoMode.isEnabled, let api, session != nil else { return }
        do {
            let current = try await validSession()
            status = try await api.accountStatus(current)
            recentTexts = try await api.recentTexts(session: current)
            lastError = nil
        } catch TextingError.notSignedIn {
            store(nil)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setPaused(_ paused: Bool) async {
        guard let api else { return }
        await run {
            try await api.setPaused(paused, session: try await self.validSession())
            self.status?.textsPaused = paused
        }
    }

    /// Called with each verified App Store transaction; the server checks it with Apple.
    func claimSubscription(transactionID: UInt64) async {
        guard let api, session != nil else { return }
        do {
            _ = try await api.verifySubscription(transactionID: transactionID, session: try await validSession())
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Sends the upcoming "Text me" occurrences to the server. Debounced.
    func scheduleSync(using container: ModelContainer, delay: TimeInterval = 1.5) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.sync(repository: Repository(context: container.mainContext))
        }
    }

    func sync(repository: Repository) async {
        guard !DemoMode.isEnabled, let api, session != nil else { return }
        let reminders = repository.reminders().map(\.plannerValue)
        let settings = repository.existingSettings()?.renderSettings() ?? RenderSettings()
        let items = OutboxPlanner.items(reminders: reminders, settings: settings)
        do {
            try await api.syncOutbox(items, timeZone: TimeZone.current.identifier, session: try await validSession())
            lastSync = Date()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Helpers

    private func validSession() async throws -> TextingSession {
        guard let api, let current = session else { throw TextingError.notSignedIn }
        guard current.needsRefresh() else { return current }
        do {
            let refreshed = try await api.refresh(current)
            store(refreshed)
            return refreshed
        } catch TextingError.server {
            // The refresh token was revoked (signed out elsewhere, account deleted).
            store(nil)
            throw TextingError.notSignedIn
        }
    }

    private func store(_ newSession: TextingSession?) {
        session = newSession
        guard !DemoMode.isEnabled else { return }
        Keychain.set(newSession.flatMap { try? JSONEncoder().encode($0) }, for: Self.sessionKey)
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            lastError = nil
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
    }

    /// Demo mode: a subscribed account with a few texts, without a server.
    private func applyDemoState() {
        session = TextingSession(accessToken: "", refreshToken: "", expiresAt: .distantFuture, userID: UUID(), phone: "+15125550142")
        status = AccountStatus(
            phone: "+15125550142", textsPaused: false, subscribed: true,
            entitledUntil: Calendar.current.date(byAdding: .day, value: 24, to: Date()),
            productID: "texts.monthly", sentThisMonth: 47, monthlyCap: 300, queued: 212
        )
        lastSync = Date().addingTimeInterval(-40)
    }

    /// Demo mode: texts "sent" by the server, filled in by DemoData.
    func setDemoTexts(_ texts: [RemoteText]) {
        guard DemoMode.isEnabled else { return }
        recentTexts = texts
    }
}

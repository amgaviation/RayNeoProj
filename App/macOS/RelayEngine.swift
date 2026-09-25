import AppKit
import Foundation
import SwiftData
import ReminderCore

/// The relay loop. Every 30 seconds it:
/// 1. checks in (heartbeat) and makes sure it is the one active relay,
/// 2. follows up on recent sends (delivered / failed → optional SMS retry),
/// 3. handles STOP / START replies,
/// 4. sends whatever automatic reminders are due, with throttling.
///
/// Every message is claimed in the shared log *before* it is handed to Messages,
/// so a crash or a second device can never cause a duplicate.
@MainActor
final class RelayEngine: ObservableObject {
    static let shared = RelayEngine()

    enum Condition: Equatable {
        case starting
        case running
        case paused
        case standby(String)
        case attention(String)

        var title: String {
            switch self {
            case .starting: return "Starting…"
            case .running: return "Running"
            case .paused: return "Paused"
            case .standby: return "Standing by"
            case .attention: return "Needs attention"
            }
        }

        var detail: String {
            switch self {
            case .starting: return "Checking permissions and iCloud."
            case .running: return "Sending automatic reminders as they come due."
            case .paused: return "Nothing is sent while paused. Missed reminders are logged when you resume."
            case .standby(let reason), .attention(let reason): return reason
            }
        }

        var needsAttention: Bool {
            if case .attention = self { return true }
            return false
        }

        var symbolName: String {
            switch self {
            case .starting: return "hourglass"
            case .running: return "paperplane.fill"
            case .paused: return "pause.circle"
            case .standby: return "moon.zzz"
            case .attention: return "exclamationmark.triangle.fill"
            }
        }
    }

    struct Event: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
        let isProblem: Bool
    }

    struct NextDue: Equatable {
        let title: String
        let date: Date
    }

    @Published private(set) var condition: Condition = .starting
    @Published private(set) var note: String?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var nextDue: NextDue?
    @Published private(set) var automation: MessagesSender.AutomationStatus = .notDetermined
    @Published private(set) var hasFullDiskAccess = false
    @Published private(set) var isChecking = false
    @Published private(set) var events: [Event] = []
    @Published private(set) var automaticRemindersSeen = 0
    @Published private(set) var peopleSeen = 0
    @Published private(set) var iCloudAccount = "Checking…"

    var sentLast24h: Int { prefs.recentSends.count }

    static let tickInterval: TimeInterval = 30
    private static let heartbeatInterval: TimeInterval = 5 * 60

    private let prefs = RelayPreferences.shared
    private var timer: Timer?
    private var lastHeartbeat: Date?
    private var lastHeartbeatCondition: Condition?
    private var lastPrune: Date?

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task {
            await refreshPermissions(ask: false)
            iCloudAccount = await DataStore.shared.iCloudAccountDescription()
            await tick()
        }
    }

    func refreshPermissions(ask: Bool) async {
        automation = await MessagesSender.automationStatus(ask: ask)
        hasFullDiskAccess = ChatDatabase.open() != nil
    }

    /// Triggers the macOS prompt that lets the relay control Messages.
    func requestAutomationAccess() async {
        automation = await MessagesSender.automationStatus(ask: true)
        if automation != .granted {
            _ = await MessagesSender.requestAutomationAccess()
            automation = await MessagesSender.automationStatus(ask: false)
        }
        await tick()
    }

    func setPaused(_ paused: Bool) {
        prefs.isPaused = paused
        if !paused {
            // Anything that came due while paused is logged as missed, not sent late.
            prefs.lastScan = Date()
        }
        Task { await tick(forceHeartbeat: true) }
    }

    // MARK: The loop

    func tick(forceHeartbeat: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let now = Date()
        // A fresh context each pass reads whatever iCloud imported since the last one.
        let context = ModelContext(DataStore.shared.container)
        let repository = Repository(context: context)
        let settings = repository.settings()
        lastCheck = now
        automaticRemindersSeen = repository.reminders().filter { $0.method == .relay && $0.isActive }.count
        peopleSeen = repository.recipients().count

        defer {
            updateNextDue(repository: repository)
            writeHeartbeat(repository, force: forceHeartbeat)
            pruneIfNeeded(repository: repository, settings: settings)
        }

        if prefs.isPaused {
            condition = .paused
            return
        }
        if let leader = otherActiveRelay(repository, now: now) {
            condition = .standby("\(leader.deviceName) is the active relay. This Mac takes over if it goes offline.")
            prefs.lastScan = now
            return
        }
        if automation != .granted {
            automation = await MessagesSender.automationStatus(ask: false)
        }
        guard automation == .granted else {
            condition = .attention(automation == .denied
                ? "macOS is blocking access to Messages. Turn on BlueNudge Relay › Messages in System Settings › Privacy & Security › Automation."
                : "Open the dashboard and click Grant access so the relay can use Messages.")
            return
        }

        let chatDB = ChatDatabase.open()
        hasFullDiskAccess = chatDB != nil
        if let chatDB {
            await followUpRecentSends(repository: repository, settings: settings, chatDB: chatDB, now: now)
            if settings.honorOptOutReplies {
                await processReplies(repository: repository, settings: settings, chatDB: chatDB)
            }
        }

        note = await sendDueMessages(repository: repository, settings: settings, chatDB: chatDB, now: now)
        prefs.lastScan = now
        condition = .running
    }

    // MARK: Sending

    /// Returns a note for the status line when sending was held back.
    private func sendDueMessages(repository: Repository, settings: SharedSettings, chatDB: ChatDatabase?, now: Date) async -> String? {
        let grace = TimeInterval(max(1, settings.graceMinutes) * 60)
        var windowStart = now.addingTimeInterval(-grace)
        if let lastScan = prefs.lastScan, lastScan < windowStart {
            windowStart = lastScan
        }
        // Overlap by a few minutes so anything crossing the grace line gets logged as
        // missed, and never look back more than a week.
        windowStart = max(windowStart.addingTimeInterval(-5 * 60), now.addingTimeInterval(-7 * 86_400))

        let plan = DuePlanner.plan(
            reminders: repository.reminders().map(\.plannerValue),
            recipients: repository.recipientDirectory(),
            method: .relay,
            alreadyHandled: repository.handledKeys(since: windowStart.addingTimeInterval(-86_400)),
            windowStart: windowStart,
            now: now,
            grace: grace,
            settings: settings.renderSettings()
        )

        let device = DeviceInfo.name
        for message in plan.missed {
            repository.record(message, status: .missed, channel: .relay, deviceName: device,
                              error: "Not sent: more than \(settings.graceMinutes) min late, usually because the Mac was asleep or offline.")
        }
        for message in plan.optedOut {
            repository.record(message, status: .optedOut, channel: .relay, deviceName: device)
        }
        for message in plan.unreachable {
            repository.record(message, status: .failed, channel: .relay, deviceName: device,
                              error: "This person has no valid phone number or email.")
        }
        repository.save()
        if !plan.missed.isEmpty {
            log("\(plan.missed.count) reminder(s) logged as missed (past the \(settings.graceMinutes)-minute window).", problem: true)
        }

        let throttle = SendThrottle(hourlyCap: settings.hourlySendCap, minimumSpacing: TimeInterval(settings.secondsBetweenSends))
        for message in plan.toSend {
            if prefs.isPaused { return nil }
            guard let delay = throttle.delayBeforeNextSend(recentSends: prefs.recentSends, now: Date()) else {
                return "Hourly limit of \(settings.hourlySendCap) reached; the rest go out as it frees up."
            }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            // Another device may have handled it meanwhile (e.g. "Send from iPhone").
            if repository.isHandled(message.key) { continue }
            await deliver(message, repository: repository, settings: settings, chatDB: chatDB)
        }
        return nil
    }

    private func deliver(_ message: PlannedMessage, repository: Repository, settings: SharedSettings, chatDB: ChatDatabase?) async {
        let record = repository.record(message, status: .sending, channel: .relay, deviceName: DeviceInfo.name)
        repository.save()

        let preferred: MessagesSender.Service = message.service == .sms ? .sms : .iMessage
        var usedService = preferred
        let started = Date()
        var outcome = await MessagesSender.send(message.text, to: message.handle, service: preferred)
        prefs.recentSends = prefs.recentSends + [started]

        if case .failed = outcome, canFallBackToSMS(handle: message.handle, service: message.service, alreadySMS: preferred == .sms, settings: settings) {
            let retry = await MessagesSender.send(message.text, to: message.handle, service: .sms)
            if retry == .sent {
                outcome = .sent
                usedService = .sms
                record.errorMessage = "iMessage failed, sent as SMS instead."
            }
        }

        let name = message.recipientName.isEmpty ? message.handle : message.recipientName
        switch outcome {
        case .sent:
            record.status = .sent
            record.sentAt = started
            record.serviceUsed = usedService.rawValue
            if let chatDB, let row = await findOutgoing(in: chatDB, handle: message.handle, since: started.addingTimeInterval(-2)) {
                record.chatMessageGUID = row.guid
                if !row.service.isEmpty { record.serviceUsed = row.service }
                if row.isDelivered {
                    record.status = .delivered
                    record.deliveredAt = row.deliveredAt ?? Date()
                }
            }
            log("Sent “\(message.reminderTitle)” to \(name) via \(record.serviceUsed).", problem: false)
        case .failed(let reason):
            record.status = .failed
            record.errorMessage = reason
            log("Couldn't send “\(message.reminderTitle)” to \(name): \(reason)", problem: true)
        case .timedOut:
            record.status = .sending
            record.errorMessage = "Messages didn't answer in time. Check Messages to see if it went out; it won't be retried automatically."
            log("Messages didn't respond while sending to \(name).", problem: true)
        }
        repository.save()
    }

    private func canFallBackToSMS(handle: String, service: MessageService, alreadySMS: Bool, settings: SharedSettings) -> Bool {
        settings.smsFallback && !alreadySMS && service == .auto && !HandleNormalizer.isEmail(handle)
    }

    private func findOutgoing(in chatDB: ChatDatabase, handle: String, since: Date) async -> ChatDatabase.Outgoing? {
        for _ in 0..<6 {
            if let row = chatDB.outgoing(to: handle, since: since).last {
                return row
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return nil
    }

    // MARK: Follow-up

    /// Updates recent relay sends from the Messages database: delivered, failed
    /// (with an SMS retry if enabled), or late confirmation of a timed-out send.
    private func followUpRecentSends(repository: Repository, settings: SharedSettings, chatDB: ChatDatabase, now: Date) async {
        let since = now.addingTimeInterval(-6 * 3_600)
        let relay = DeliveryChannel.relay.rawValue
        let sent = DeliveryStatus.sent.rawValue
        let sending = DeliveryStatus.sending.rawValue
        let descriptor = FetchDescriptor<DeliveryRecord>(
            predicate: #Predicate { record in
                record.channelRaw == relay
                    && (record.statusRaw == sent || record.statusRaw == sending)
                    && record.createdAt >= since
            }
        )
        guard let records = try? repository.context.fetch(descriptor), !records.isEmpty else { return }
        let device = DeviceInfo.name

        for record in records where record.deviceName == device {
            let row: ChatDatabase.Outgoing?
            if !record.chatMessageGUID.isEmpty {
                row = chatDB.outgoing(guid: record.chatMessageGUID)
            } else {
                let from = (record.sentAt ?? record.createdAt).addingTimeInterval(-2)
                row = chatDB.outgoing(to: record.recipientHandle, since: from, limit: 1).first
                if let row { record.chatMessageGUID = row.guid }
            }
            guard let row else { continue }

            if row.error != 0 {
                let recipientService = record.recipientID.flatMap { repository.recipient(id: $0) }?.service ?? .auto
                if canFallBackToSMS(handle: record.recipientHandle, service: recipientService, alreadySMS: record.serviceUsed == "SMS", settings: settings) {
                    let outcome = await MessagesSender.send(record.messageText, to: record.recipientHandle, service: .sms)
                    prefs.recentSends = prefs.recentSends + [Date()]
                    if outcome == .sent {
                        record.status = .sent
                        record.serviceUsed = "SMS"
                        record.chatMessageGUID = ""
                        record.sentAt = Date()
                        record.errorMessage = "iMessage wasn't delivered, resent as SMS."
                        log("Resent to \(record.displayRecipient) as SMS after iMessage failed.", problem: false)
                        continue
                    }
                }
                record.status = .failed
                record.errorMessage = "Messages couldn't deliver it (error \(row.error)). The number may not use iMessage; try SMS fallback."
                log("Delivery failed for \(record.displayRecipient) (error \(row.error)).", problem: true)
            } else if row.isDelivered {
                if record.sentAt == nil { record.sentAt = row.date }
                record.status = .delivered
                record.deliveredAt = row.deliveredAt ?? Date()
                if !row.service.isEmpty { record.serviceUsed = row.service }
            } else if record.status == .sending {
                record.status = .sent
                record.sentAt = row.date
                record.errorMessage = ""
            }
        }
        repository.save()
    }

    // MARK: Replies

    private func processReplies(repository: Repository, settings: SharedSettings, chatDB: ChatDatabase) async {
        guard let lastRowID = prefs.lastInboundRowID else {
            // First run: start from now instead of scanning years of history.
            prefs.lastInboundRowID = chatDB.maxMessageRowID()
            return
        }
        let incoming = chatDB.incoming(afterRowID: lastRowID)
        guard !incoming.isEmpty else { return }
        let recipients = repository.recipients()
        let countryCode = settings.defaultCountryCode

        for reply in incoming {
            prefs.lastInboundRowID = reply.rowID
            guard let intent = OptOutDetector.classify(reply.text) else { continue }
            let normalized = HandleNormalizer.normalize(reply.handle, defaultCountryCode: countryCode) ?? reply.handle.lowercased()
            let matches = recipients.filter { $0.handle == normalized }
            guard let first = matches.first else { continue }

            switch intent {
            case .optOut:
                let newlyOptedOut = matches.filter { !$0.optedOut }
                guard !newlyOptedOut.isEmpty else { continue }
                for recipient in newlyOptedOut {
                    recipient.setOptedOut(true, source: "reply")
                }
                let entry = PlannedMessage(
                    key: "optout|\(prefs.deviceID)|\(reply.rowID)",
                    reminderID: first.id,
                    recipientID: first.id,
                    occurrence: reply.date,
                    reminderTitle: "Opted out by reply",
                    recipientName: first.name,
                    handle: normalized,
                    service: .auto,
                    text: reply.text
                )
                let record = repository.record(entry, status: .optedOut, channel: .relay, deviceName: DeviceInfo.name,
                                               error: "They replied “\(reply.text)” and won't get further reminders.")
                record.reminderID = nil
                repository.save()
                log("\(first.displayName) opted out by replying “\(reply.text)”.", problem: false)

                if settings.sendOptOutConfirmation {
                    let confirmation = settings.optOutConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !confirmation.isEmpty {
                        let service: MessagesSender.Service = reply.service.uppercased() == "SMS" ? .sms : .iMessage
                        _ = await MessagesSender.send(confirmation, to: reply.handle, service: service)
                        prefs.recentSends = prefs.recentSends + [Date()]
                    }
                }
            case .optIn:
                // START only reverses opt-outs that came from a reply, never ones
                // you set by hand in the app.
                let resubscribed = matches.filter { $0.optedOut && $0.optOutSource == "reply" }
                guard !resubscribed.isEmpty else { continue }
                for recipient in resubscribed {
                    recipient.setOptedOut(false, source: "reply")
                }
                repository.save()
                log("\(first.displayName) opted back in by replying “\(reply.text)”.", problem: false)
            }
        }
    }

    // MARK: Heartbeat and housekeeping

    private func otherActiveRelay(_ repository: Repository, now: Date) -> RelayHeartbeat? {
        let me = prefs.deviceID
        return repository.heartbeats()
            .filter { $0.deviceID != me && $0.isOnline(now: now) && !$0.isPaused && !$0.needsAttention }
            .filter { $0.deviceID < me }
            .first
    }

    private func writeHeartbeat(_ repository: Repository, force: Bool) {
        let now = Date()
        if !force, let last = lastHeartbeat, now.timeIntervalSince(last) < Self.heartbeatInterval, lastHeartbeatCondition == condition {
            return
        }
        let deviceID = prefs.deviceID
        let descriptor = FetchDescriptor<RelayHeartbeat>(predicate: #Predicate { $0.deviceID == deviceID })
        let existing = (try? repository.context.fetch(descriptor)) ?? []
        let heartbeat: RelayHeartbeat
        if let first = existing.first {
            heartbeat = first
            for duplicate in existing.dropFirst() { repository.context.delete(duplicate) }
        } else {
            heartbeat = RelayHeartbeat(deviceID: deviceID, deviceName: DeviceInfo.name)
            repository.context.insert(heartbeat)
        }
        heartbeat.deviceName = DeviceInfo.name
        heartbeat.lastSeen = now
        heartbeat.appVersion = DeviceInfo.appVersion
        heartbeat.macOSVersion = DeviceInfo.osVersion
        heartbeat.isPaused = prefs.isPaused
        heartbeat.needsAttention = condition.needsAttention
        switch condition {
        case .running:
            heartbeat.statusText = note ?? ""
        case .starting, .paused:
            heartbeat.statusText = condition.title
        case .standby(let reason), .attention(let reason):
            heartbeat.statusText = reason
        }
        let sends = prefs.recentSends
        heartbeat.sentLast24h = sends.count
        heartbeat.lastSendAt = sends.max()
        repository.save()
        lastHeartbeat = now
        lastHeartbeatCondition = condition
    }

    private func pruneIfNeeded(repository: Repository, settings: SharedSettings) {
        let now = Date()
        if let lastPrune, now.timeIntervalSince(lastPrune) < 6 * 3_600 { return }
        lastPrune = now
        repository.pruneDeliveries(olderThanDays: settings.logRetentionDays, now: now)
        let staleCutoff = now.addingTimeInterval(-30 * 86_400)
        for heartbeat in repository.heartbeats() where heartbeat.lastSeen < staleCutoff {
            repository.context.delete(heartbeat)
        }
        repository.save()
    }

    private func updateNextDue(repository: Repository) {
        let reminders = repository.reminders().filter { $0.method == .relay && $0.isActive }
        let upcoming = DuePlanner.upcoming(
            reminders: reminders.map(\.plannerValue),
            method: .relay,
            after: Date(),
            horizon: 60 * 86_400,
            limit: 1
        )
        if let first = upcoming.first, let reminder = reminders.first(where: { $0.id == first.reminderID }) {
            nextDue = NextDue(title: reminder.displayTitle, date: first.occurrence)
        } else {
            nextDue = nil
        }
    }

    // MARK: Test and log

    /// Sends a one-off test message without touching the reminder log.
    func sendTest(to rawHandle: String, text: String, service: MessagesSender.Service) async -> String {
        let repository = Repository(context: ModelContext(DataStore.shared.container))
        let countryCode = repository.settings().defaultCountryCode
        guard let handle = HandleNormalizer.normalize(rawHandle, defaultCountryCode: countryCode) else {
            return "That isn't a valid phone number or email."
        }
        let outcome = await MessagesSender.send(text, to: handle, service: service)
        switch outcome {
        case .sent:
            log("Test message sent to \(handle).", problem: false)
            return "Sent to \(HandleNormalizer.displayFormat(handle)). Check Messages to confirm it was delivered."
        case .failed(let reason):
            log("Test message to \(handle) failed: \(reason)", problem: true)
            return "Failed: \(reason)"
        case .timedOut:
            return "Messages didn't respond in time. Open Messages and check it's signed in."
        }
    }

    func forgetOtherRelays() {
        let repository = Repository(context: ModelContext(DataStore.shared.container))
        for heartbeat in repository.heartbeats() where heartbeat.deviceID != prefs.deviceID {
            repository.context.delete(heartbeat)
        }
        repository.save()
        Task { await tick(forceHeartbeat: true) }
    }

    private func log(_ text: String, problem: Bool) {
        events.insert(Event(date: Date(), text: text, isProblem: problem), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
    }
}

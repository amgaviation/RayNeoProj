import Foundation
import SwiftData
import ReminderCore

/// Read/write helpers shared by the iPhone app and the Mac relay. Main-actor
/// only, like the `ModelContext` it wraps.
@MainActor
struct Repository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Settings

    /// The single settings record, created on first use. Copies created on two
    /// devices before they first synced are collapsed onto the oldest one.
    @discardableResult
    func settings() -> SharedSettings {
        let descriptor = FetchDescriptor<SharedSettings>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        let all = (try? context.fetch(descriptor)) ?? []
        if let first = all.first {
            for duplicate in all.dropFirst() {
                context.delete(duplicate)
            }
            if all.count > 1 { save() }
            return first
        }
        let created = SharedSettings()
        created.defaultCountryCode = CallingCodes.callingCode(forRegion: Locale.current.region?.identifier)
        context.insert(created)
        save()
        return created
    }

    /// The settings record if one exists, without creating it. Use this from
    /// view code, which must not insert models while rendering.
    func existingSettings() -> SharedSettings? {
        var descriptor = FetchDescriptor<SharedSettings>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: You

    /// The phone number or email your reminder texts go to. Copies created on
    /// two devices before they first synced collapse onto the oldest one.
    func me() -> Recipient? {
        let descriptor = FetchDescriptor<Recipient>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        let all = (try? context.fetch(descriptor)) ?? []
        guard let first = all.first else { return nil }
        if all.count > 1 {
            for duplicate in all.dropFirst() {
                for reminder in reminders() where reminder.recipientIDs.contains(duplicate.id) {
                    reminder.recipientIDs = reminder.recipientIDs.map { $0 == duplicate.id ? first.id : $0 }
                }
                context.delete(duplicate)
            }
            save()
        }
        return first
    }

    /// Sets where texts go. Returns nil when `raw` isn't a phone number or email.
    @discardableResult
    func setMyHandle(_ raw: String, name: String = "Me") -> Recipient? {
        let countryCode = existingSettings()?.defaultCountryCode ?? "1"
        guard let handle = HandleNormalizer.normalize(raw, defaultCountryCode: countryCode) else { return nil }
        let recipient: Recipient
        if let existing = me() {
            recipient = existing
            recipient.rawHandle = raw
            recipient.handle = handle
            recipient.updatedAt = Date()
        } else {
            recipient = Recipient(name: name, rawHandle: raw, handle: handle)
            context.insert(recipient)
        }
        // Text reminders created before a number was set start going to it now.
        for reminder in reminders() where reminder.recipientIDs.isEmpty {
            reminder.recipientIDs = [recipient.id]
        }
        save()
        return recipient
    }

    /// A one-time reminder, e.g. from Siri or a SNOOZE reply. Texted when a
    /// number is set and texts are the default; otherwise a notification.
    @discardableResult
    func addOneTimeReminder(
        title: String,
        message: String,
        at date: Date,
        method: DeliveryMethod? = nil,
        isSnooze: Bool = false,
        now: Date = Date()
    ) -> Reminder {
        let me = me()
        let resolved = method ?? (me == nil ? .notification : (existingSettings()?.defaultMethod ?? .relay))
        // Whole minutes, rounded up, so "in 10 minutes" is never early.
        let start = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)
        let reminder = Reminder(
            title: title,
            messageTemplate: message,
            schedule: Schedule(frequency: .once, start: start, timeZoneIdentifier: TimeZone.current.identifier),
            recipientIDs: me.map { [$0.id] } ?? [],
            method: resolved
        )
        reminder.activeSince = now
        if isSnooze { reminder.notes = Reminder.snoozeNote }
        context.insert(reminder)
        save()
        return reminder
    }

    /// Removes snoozed copies a day after they went out, so the list stays tidy.
    func pruneFinishedSnoozes(now: Date = Date()) {
        let note = Reminder.snoozeNote
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.notes == note })
        guard let snoozes = try? context.fetch(descriptor) else { return }
        var removed = false
        for reminder in snoozes where reminder.schedule.start < now.addingTimeInterval(-86_400) {
            context.delete(reminder)
            removed = true
        }
        if removed { save() }
    }

    // MARK: Fetching

    func reminders() -> [Reminder] {
        let descriptor = FetchDescriptor<Reminder>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func recipients() -> [Recipient] {
        let descriptor = FetchDescriptor<Recipient>(sortBy: [SortDescriptor(\.name, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func recipientDirectory() -> [UUID: PlannerRecipient] {
        var directory: [UUID: PlannerRecipient] = [:]
        for recipient in recipients() {
            directory[recipient.id] = recipient.plannerValue
        }
        return directory
    }

    func reminder(id: UUID) -> Reminder? {
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func recipient(id: UUID) -> Recipient? {
        let descriptor = FetchDescriptor<Recipient>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// Delivery records for occurrences at or after `date`.
    func deliveries(since date: Date) -> [DeliveryRecord] {
        let descriptor = FetchDescriptor<DeliveryRecord>(
            predicate: #Predicate { $0.occurrenceDate >= date },
            sortBy: [SortDescriptor(\.occurrenceDate, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Occurrence keys already handled (by any device) since `date`.
    func handledKeys(since date: Date) -> Set<String> {
        Set(deliveries(since: date).map(\.occurrenceKey))
    }

    /// True when any device has already recorded this occurrence key.
    func isHandled(_ key: String) -> Bool {
        var descriptor = FetchDescriptor<DeliveryRecord>(predicate: #Predicate { $0.occurrenceKey == key })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Relay sends still waiting for a delivery confirmation, newest first.
    func relaySendsAwaitingConfirmation(since date: Date) -> [DeliveryRecord] {
        let relay = DeliveryChannel.relay.rawValue
        let sent = DeliveryStatus.sent.rawValue
        let sending = DeliveryStatus.sending.rawValue
        let descriptor = FetchDescriptor<DeliveryRecord>(
            predicate: #Predicate { record in
                record.channelRaw == relay
                    && (record.statusRaw == sent || record.statusRaw == sending)
                    && record.createdAt >= date
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The newest delivery records for one person, for their detail screen.
    static func deliveriesDescriptor(recipientID: UUID?, limit: Int) -> FetchDescriptor<DeliveryRecord> {
        var descriptor = FetchDescriptor<DeliveryRecord>(
            predicate: #Predicate { $0.recipientID == recipientID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Heartbeat records for one relay Mac (normally exactly one).
    func heartbeats(deviceID: String) -> [RelayHeartbeat] {
        let descriptor = FetchDescriptor<RelayHeartbeat>(predicate: #Predicate { $0.deviceID == deviceID })
        return (try? context.fetch(descriptor)) ?? []
    }

    func heartbeats() -> [RelayHeartbeat] {
        let descriptor = FetchDescriptor<RelayHeartbeat>(sortBy: [SortDescriptor(\.lastSeen, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The most recently seen relay, if any has ever checked in.
    func latestHeartbeat() -> RelayHeartbeat? {
        heartbeats().first
    }

    // MARK: Planning

    /// Messages due for `method`, looking back `lookback` seconds.
    func plan(method: DeliveryMethod, lookback: TimeInterval, grace: TimeInterval, now: Date = Date()) -> DuePlan {
        let renderSettings = existingSettings()?.renderSettings() ?? RenderSettings()
        let windowStart = now.addingTimeInterval(-lookback)
        return DuePlanner.plan(
            reminders: reminders().map(\.plannerValue),
            recipients: recipientDirectory(),
            method: method,
            alreadyHandled: handledKeys(since: windowStart.addingTimeInterval(-86_400)),
            windowStart: windowStart,
            now: now,
            grace: grace,
            settings: renderSettings
        )
    }

    // MARK: Writing

    /// Records the outcome for one message. Returns the new record.
    @discardableResult
    func record(
        _ message: PlannedMessage,
        status: DeliveryStatus,
        channel: DeliveryChannel,
        deviceName: String,
        error: String = ""
    ) -> DeliveryRecord {
        let record = DeliveryRecord(
            message: message,
            status: status,
            channel: channel,
            deviceName: deviceName,
            errorMessage: error
        )
        context.insert(record)
        return record
    }

    /// Deletes a recipient and removes it from every reminder that lists it.
    func delete(_ recipient: Recipient) {
        let id = recipient.id
        for reminder in reminders() where reminder.recipientIDs.contains(id) {
            reminder.recipientIDs = reminder.recipientIDs.filter { $0 != id }
            reminder.updatedAt = Date()
        }
        context.delete(recipient)
        save()
    }

    func delete(_ reminder: Reminder) {
        context.delete(reminder)
        save()
    }

    /// Drops delivery records older than the retention period.
    func pruneDeliveries(olderThanDays days: Int, now: Date = Date()) {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let descriptor = FetchDescriptor<DeliveryRecord>(predicate: #Predicate { $0.occurrenceDate < cutoff })
        guard let old = try? context.fetch(descriptor), !old.isEmpty else { return }
        for record in old { context.delete(record) }
        save()
    }

    /// Finds a recipient by any spelling of their phone number or email.
    func recipient(matchingHandle handle: String, defaultCountryCode: String) -> Recipient? {
        let normalized = HandleNormalizer.normalize(handle, defaultCountryCode: defaultCountryCode) ?? handle.lowercased()
        return recipients().first { $0.handle == normalized }
    }

    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            NSLog("BlueNudge: save failed: \(error)")
        }
    }
}

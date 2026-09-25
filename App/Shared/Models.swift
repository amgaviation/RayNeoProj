import Foundation
import SwiftData
import ReminderCore

// These models sync through the iCloud (CloudKit) private database, so they follow
// CloudKit's rules: every property has a default or is optional, no unique
// constraints, and no relationships. Links between records are stored as UUIDs,
// which also keeps the delivery log intact after a reminder or person is deleted.
//
// Both apps compile this same file; the iPhone app and the Mac relay must always
// agree on these definitions. In production CloudKit you can add properties but
// never rename or remove them.

/// Someone who receives reminders.
@Model
final class Recipient {
    var id: UUID = UUID()
    var name: String = ""
    /// Exactly what was typed or imported, kept for editing.
    var rawHandle: String = ""
    /// E.164 phone number or lowercase email; empty when `rawHandle` is unusable.
    var handle: String = ""
    var notes: String = ""
    var optedOut: Bool = false
    var optedOutAt: Date?
    /// "reply" when detected from a STOP message, "manual" when set in the app.
    var optOutSource: String = ""
    var serviceRaw: String = MessageService.auto.rawValue
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(name: String, rawHandle: String, handle: String, notes: String = "") {
        self.id = UUID()
        self.name = name
        self.rawHandle = rawHandle
        self.handle = handle
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var service: MessageService {
        get { MessageService(rawValue: serviceRaw) ?? .auto }
        set { serviceRaw = newValue.rawValue }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? displayHandle : trimmed
    }

    var displayHandle: String {
        handle.isEmpty ? rawHandle : HandleNormalizer.displayFormat(handle)
    }

    var hasValidHandle: Bool { !handle.isEmpty }

    var plannerValue: PlannerRecipient {
        PlannerRecipient(id: id, name: name, handle: handle, optedOut: optedOut, service: service)
    }

    func setOptedOut(_ value: Bool, source: String) {
        optedOut = value
        optedOutAt = value ? Date() : nil
        optOutSource = value ? source : ""
        updatedAt = Date()
    }
}

/// A scheduled message to one or more recipients.
@Model
final class Reminder {
    var id: UUID = UUID()
    var title: String = ""
    var messageTemplate: String = ""
    /// `Schedule` as JSON (see `ScheduleCoding`).
    var scheduleJSON: String = ""
    /// Comma-separated recipient UUIDs.
    var recipientIDsRaw: String = ""
    var methodRaw: String = DeliveryMethod.tapToSend.rawValue
    var isActive: Bool = true
    /// Occurrences before this are never sent. Reset when the schedule changes or
    /// the reminder is switched back on.
    var activeSince: Date = Date()
    var notes: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(title: String, messageTemplate: String, schedule: Schedule, recipientIDs: [UUID], method: DeliveryMethod) {
        self.id = UUID()
        self.title = title
        self.messageTemplate = messageTemplate
        self.scheduleJSON = ScheduleCoding.encode(schedule)
        self.recipientIDsRaw = recipientIDs.map(\.uuidString).joined(separator: ",")
        self.methodRaw = method.rawValue
        self.isActive = true
        self.activeSince = Date()
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var schedule: Schedule {
        get { ScheduleCoding.decode(scheduleJSON) ?? Schedule(frequency: .once, start: createdAt) }
        set { scheduleJSON = ScheduleCoding.encode(newValue) }
    }

    var recipientIDs: [UUID] {
        get {
            recipientIDsRaw
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }
        }
        set { recipientIDsRaw = newValue.map(\.uuidString).joined(separator: ",") }
    }

    var method: DeliveryMethod {
        get { DeliveryMethod(rawValue: methodRaw) ?? .tapToSend }
        set { methodRaw = newValue.rawValue }
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled reminder" : trimmed
    }

    var plannerValue: PlannerReminder {
        PlannerReminder(
            id: id,
            title: title,
            template: messageTemplate,
            schedule: schedule,
            recipientIDs: recipientIDs,
            method: method,
            isActive: isActive,
            activeSince: activeSince
        )
    }

    func nextOccurrence(after date: Date = Date()) -> Date? {
        guard isActive else { return nil }
        return schedule.nextOccurrence(after: max(date, activeSince.addingTimeInterval(-1)))
    }
}

/// What happened to one message. Written by whichever device handled it.
@Model
final class DeliveryRecord {
    var id: UUID = UUID()
    /// See `OccurrenceKey`. Presence of a record for a key means "handled".
    var occurrenceKey: String = ""
    var reminderID: UUID?
    var recipientID: UUID?
    var occurrenceDate: Date = Date()
    var statusRaw: String = DeliveryStatus.sent.rawValue
    var channelRaw: String = DeliveryChannel.relay.rawValue
    /// "iMessage" or "SMS" once known.
    var serviceUsed: String = ""
    var createdAt: Date = Date()
    var sentAt: Date?
    var deliveredAt: Date?
    var readAt: Date?
    var errorMessage: String = ""
    var messageText: String = ""
    var recipientName: String = ""
    var recipientHandle: String = ""
    var reminderTitle: String = ""
    var deviceName: String = ""
    /// The Messages row this send matched, used to follow up on delivery.
    var chatMessageGUID: String = ""

    init(
        message: PlannedMessage,
        status: DeliveryStatus,
        channel: DeliveryChannel,
        deviceName: String,
        errorMessage: String = ""
    ) {
        self.id = UUID()
        self.occurrenceKey = message.key
        self.reminderID = message.reminderID
        self.recipientID = message.recipientID
        self.occurrenceDate = message.occurrence
        self.statusRaw = status.rawValue
        self.channelRaw = channel.rawValue
        self.createdAt = Date()
        self.sentAt = status.countsAsSent ? Date() : nil
        self.errorMessage = errorMessage
        self.messageText = message.text
        self.recipientName = message.recipientName
        self.recipientHandle = message.handle
        self.reminderTitle = message.reminderTitle
        self.deviceName = deviceName
    }

    var status: DeliveryStatus {
        get { DeliveryStatus(rawValue: statusRaw) ?? .sent }
        set { statusRaw = newValue.rawValue }
    }

    var channel: DeliveryChannel {
        get { DeliveryChannel(rawValue: channelRaw) ?? .relay }
        set { channelRaw = newValue.rawValue }
    }

    var displayRecipient: String {
        recipientName.isEmpty ? HandleNormalizer.displayFormat(recipientHandle) : recipientName
    }
}

/// Each relay Mac reports in here so the iPhone can show whether it is online.
@Model
final class RelayHeartbeat {
    var deviceID: String = ""
    var deviceName: String = ""
    var lastSeen: Date = Date.distantPast
    var appVersion: String = ""
    var macOSVersion: String = ""
    var isPaused: Bool = false
    var needsAttention: Bool = false
    var statusText: String = ""
    var sentLast24h: Int = 0
    var lastSendAt: Date?

    init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.lastSeen = Date()
    }

    /// Considered online when it checked in within the last 12 minutes
    /// (it checks in every 5, and iCloud can lag a few minutes).
    func isOnline(now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSeen) < 12 * 60
    }
}

/// Settings both apps read. One record; duplicates created before the first sync
/// are merged by `Repository.settings()`.
@Model
final class SharedSettings {
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Replaces `{sender}` in messages.
    var senderName: String = ""
    /// Calling code for numbers typed without one.
    var defaultCountryCode: String = "1"
    var defaultMethodRaw: String = DeliveryMethod.tapToSend.rawValue
    var appendOptOutFooter: Bool = false
    var optOutFooterText: String = "Reply STOP to opt out."
    /// Relay: mark people opted out when they reply STOP (needs Full Disk Access).
    var honorOptOutReplies: Bool = true
    var sendOptOutConfirmation: Bool = true
    var optOutConfirmationText: String = "You're unsubscribed and won't get more reminders from this number. Reply START to resubscribe."
    /// Relay: how late a reminder may still go out, e.g. after the Mac wakes up.
    var graceMinutes: Int = 60
    /// Relay: cap per rolling hour to keep the Apple ID in good standing.
    var hourlySendCap: Int = 60
    var secondsBetweenSends: Int = 3
    /// Relay: retry over SMS (through the paired iPhone) when iMessage fails.
    var smsFallback: Bool = false
    var logRetentionDays: Int = 180

    init() {
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var defaultMethod: DeliveryMethod {
        get { DeliveryMethod(rawValue: defaultMethodRaw) ?? .tapToSend }
        set { defaultMethodRaw = newValue.rawValue }
    }

    func renderSettings(locale: Locale = .current) -> RenderSettings {
        RenderSettings(
            senderName: senderName,
            locale: locale,
            footer: appendOptOutFooter ? optOutFooterText : ""
        )
    }
}

enum AppSchema {
    static var models: [any PersistentModel.Type] {
        [Recipient.self, Reminder.self, DeliveryRecord.self, RelayHeartbeat.self, SharedSettings.self]
    }
}

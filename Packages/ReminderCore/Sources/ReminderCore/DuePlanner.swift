import Foundation

/// Identifies one message: a reminder, a recipient and one occurrence time.
/// Delivery records store it, which is how every device knows what was handled.
public enum OccurrenceKey {
    public static func make(reminderID: UUID, recipientID: UUID, occurrence: Date) -> String {
        let seconds = Int64(occurrence.timeIntervalSince1970.rounded())
        return "\(reminderID.uuidString)|\(recipientID.uuidString)|\(seconds)"
    }

    public static func parse(_ key: String) -> (reminderID: UUID, recipientID: UUID, occurrence: Date)? {
        let parts = key.split(separator: "|")
        guard parts.count == 3,
              let reminderID = UUID(uuidString: String(parts[0])),
              let recipientID = UUID(uuidString: String(parts[1])),
              let seconds = Int64(parts[2]) else { return nil }
        return (reminderID, recipientID, Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}

/// A reminder reduced to what the planner needs.
public struct PlannerReminder: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var template: String
    public var schedule: Schedule
    public var recipientIDs: [UUID]
    public var method: DeliveryMethod
    public var isActive: Bool
    /// Occurrences before this instant are never sent. Moves forward whenever the
    /// schedule is edited or the reminder is switched back on, so an edit never
    /// triggers a burst of "past" messages.
    public var activeSince: Date

    public init(
        id: UUID,
        title: String,
        template: String,
        schedule: Schedule,
        recipientIDs: [UUID],
        method: DeliveryMethod,
        isActive: Bool,
        activeSince: Date
    ) {
        self.id = id
        self.title = title
        self.template = template
        self.schedule = schedule
        self.recipientIDs = recipientIDs
        self.method = method
        self.isActive = isActive
        self.activeSince = activeSince
    }
}

/// A recipient reduced to what the planner needs.
public struct PlannerRecipient: Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Normalized phone (E.164) or lowercase email. Empty when unusable.
    public var handle: String
    public var optedOut: Bool
    public var service: MessageService

    public init(id: UUID, name: String, handle: String, optedOut: Bool, service: MessageService = .auto) {
        self.id = id
        self.name = name
        self.handle = handle
        self.optedOut = optedOut
        self.service = service
    }
}

/// One concrete message the planner decided something about.
public struct PlannedMessage: Identifiable, Equatable, Sendable {
    public var key: String
    public var reminderID: UUID
    public var recipientID: UUID
    public var occurrence: Date
    public var reminderTitle: String
    public var recipientName: String
    public var handle: String
    public var service: MessageService
    public var text: String

    public var id: String { key }

    public init(
        key: String,
        reminderID: UUID,
        recipientID: UUID,
        occurrence: Date,
        reminderTitle: String,
        recipientName: String,
        handle: String,
        service: MessageService,
        text: String
    ) {
        self.key = key
        self.reminderID = reminderID
        self.recipientID = recipientID
        self.occurrence = occurrence
        self.reminderTitle = reminderTitle
        self.recipientName = recipientName
        self.handle = handle
        self.service = service
        self.text = text
    }
}

public struct DuePlan: Equatable, Sendable {
    /// Due now and within the grace window, oldest first.
    public var toSend: [PlannedMessage] = []
    /// Due, but later than the grace window allows.
    public var missed: [PlannedMessage] = []
    /// Due, but the recipient opted out.
    public var optedOut: [PlannedMessage] = []
    /// Due, but the recipient has no usable phone number or email.
    public var unreachable: [PlannedMessage] = []

    public init() {}

    public var isEmpty: Bool {
        toSend.isEmpty && missed.isEmpty && optedOut.isEmpty && unreachable.isEmpty
    }
}

/// Decides which messages are due. Pure and deterministic: the relay, the
/// iPhone send queue and the Shortcuts actions all share it.
public enum DuePlanner {
    public static func plan(
        reminders: [PlannerReminder],
        recipients: [UUID: PlannerRecipient],
        method: DeliveryMethod,
        alreadyHandled: Set<String>,
        windowStart: Date,
        now: Date,
        grace: TimeInterval,
        settings: RenderSettings,
        maxOccurrencesPerReminder: Int = 500
    ) -> DuePlan {
        var plan = DuePlan()

        for reminder in reminders where reminder.isActive && reminder.method == method {
            let lower = max(windowStart, reminder.activeSince)
            guard lower <= now else { continue }
            let occurrences = reminder.schedule.occurrences(
                from: lower,
                through: now,
                limit: maxOccurrencesPerReminder
            )
            guard !occurrences.isEmpty else { continue }

            var seen = Set<UUID>()
            let recipientIDs = reminder.recipientIDs.filter { seen.insert($0).inserted }

            for occurrence in occurrences {
                for recipientID in recipientIDs {
                    guard let recipient = recipients[recipientID] else { continue }
                    let key = OccurrenceKey.make(
                        reminderID: reminder.id,
                        recipientID: recipientID,
                        occurrence: occurrence
                    )
                    if alreadyHandled.contains(key) { continue }

                    let text = TemplateRenderer.render(
                        template: reminder.template,
                        recipientName: recipient.name,
                        reminderTitle: reminder.title,
                        occurrence: occurrence,
                        timeZone: reminder.schedule.timeZone,
                        settings: settings
                    )
                    let message = PlannedMessage(
                        key: key,
                        reminderID: reminder.id,
                        recipientID: recipientID,
                        occurrence: occurrence,
                        reminderTitle: reminder.title,
                        recipientName: recipient.name,
                        handle: recipient.handle,
                        service: recipient.service,
                        text: text
                    )

                    if recipient.optedOut {
                        plan.optedOut.append(message)
                    } else if recipient.handle.isEmpty {
                        plan.unreachable.append(message)
                    } else if now.timeIntervalSince(occurrence) > grace {
                        plan.missed.append(message)
                    } else {
                        plan.toSend.append(message)
                    }
                }
            }
        }

        let byTime: (PlannedMessage, PlannedMessage) -> Bool = {
            $0.occurrence == $1.occurrence ? $0.key < $1.key : $0.occurrence < $1.occurrence
        }
        plan.toSend.sort(by: byTime)
        plan.missed.sort(by: byTime)
        plan.optedOut.sort(by: byTime)
        plan.unreachable.sort(by: byTime)
        return plan
    }

    /// Upcoming occurrences across reminders, soonest first, for "Upcoming" lists
    /// and for scheduling iPhone notifications.
    public static func upcoming(
        reminders: [PlannerReminder],
        method: DeliveryMethod?,
        after now: Date,
        horizon: TimeInterval,
        limit: Int
    ) -> [(reminderID: UUID, occurrence: Date)] {
        var items: [(reminderID: UUID, occurrence: Date)] = []
        let upper = now.addingTimeInterval(horizon)
        for reminder in reminders where reminder.isActive {
            if let method, reminder.method != method { continue }
            let lower = max(now, reminder.activeSince)
            for date in reminder.schedule.occurrences(from: lower, through: upper, limit: limit) where date > now {
                items.append((reminder.id, date))
            }
        }
        items.sort { $0.occurrence == $1.occurrence ? $0.reminderID.uuidString < $1.reminderID.uuidString : $0.occurrence < $1.occurrence }
        return Array(items.prefix(limit))
    }
}

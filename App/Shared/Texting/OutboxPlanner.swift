import Foundation
import ReminderCore

/// Turns "Text me" reminders into the upcoming texts the server should send.
/// It uses the same planner as "Next up", so what the app shows is what's sent.
enum OutboxPlanner {
    /// How far ahead to queue. The app refreshes the queue whenever it opens and
    /// in the background, so this only matters if it isn't opened for weeks.
    static let horizon: TimeInterval = 45 * 86_400
    /// Stays under the server's per-sync limit.
    static let limit = 900
    /// Three SMS segments.
    static let maxLength = 480

    static func items(reminders: [PlannerReminder], settings: RenderSettings, now: Date = Date()) -> [OutboxItem] {
        var byID: [UUID: PlannerReminder] = [:]
        for reminder in reminders { byID[reminder.id] = reminder }
        let upcoming = DuePlanner.upcoming(reminders: reminders, method: .sms, after: now, horizon: horizon, limit: limit)
        return upcoming.compactMap { item in
            guard let reminder = byID[item.reminderID] else { return nil }
            let text = TemplateRenderer.render(
                template: reminder.template,
                recipientName: "",
                reminderTitle: reminder.title,
                occurrence: item.occurrence,
                timeZone: reminder.schedule.timeZone,
                settings: settings
            )
            let body = String(text.prefix(maxLength))
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return OutboxItem(
                key: key(reminderID: reminder.id, occurrence: item.occurrence),
                reminderID: reminder.id,
                title: String(reminder.title.prefix(120)),
                body: body,
                fireAt: item.occurrence
            )
        }
    }

    static func key(reminderID: UUID, occurrence: Date) -> String {
        "\(reminderID.uuidString)|sms|\(Int64(occurrence.timeIntervalSince1970.rounded()))"
    }
}

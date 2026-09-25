import Foundation
import UserNotifications
import ReminderCore

/// Schedules the local notifications for "Notification only" reminders.
///
/// iOS allows 64 pending notifications per app, so only the next 60 occurrences
/// are scheduled; the list is rebuilt whenever the app opens or data changes.
@MainActor
enum NotificationScheduler {
    static let categoryID = "REMINDER"
    static let snoozeAction = "SNOOZE_10"
    private static let occurrencePrefix = "occ|"
    private static let snoozePrefix = "snooze|"
    private static let maxScheduled = 60

    static func registerCategories() {
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "Snooze 10 minutes", options: [])
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Replaces all scheduled reminder notifications with the next occurrences.
    static func reschedule(using repository: Repository) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }

        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(occurrencePrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        let reminders = repository.reminders()
        var reminderByID: [UUID: Reminder] = [:]
        for reminder in reminders { reminderByID[reminder.id] = reminder }
        let settings = repository.existingSettings()?.renderSettings() ?? RenderSettings()

        let upcoming = DuePlanner.upcoming(
            reminders: reminders.map(\.plannerValue),
            method: .notification,
            after: Date(),
            horizon: 60 * 86_400,
            limit: maxScheduled
        )

        for item in upcoming {
            guard let reminder = reminderByID[item.reminderID] else { continue }
            let content = UNMutableNotificationContent()
            content.title = reminder.displayTitle
            content.body = TemplateRenderer.render(
                template: reminder.messageTemplate,
                recipientName: "",
                reminderTitle: reminder.title,
                occurrence: item.occurrence,
                timeZone: reminder.schedule.timeZone,
                settings: settings
            )
            content.sound = .default
            content.categoryIdentifier = categoryID
            content.threadIdentifier = reminder.id.uuidString
            content.interruptionLevel = .active

            let delay = max(1, item.occurrence.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let identifier = occurrencePrefix + reminder.id.uuidString + "|" + String(Int64(item.occurrence.timeIntervalSince1970))
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            } catch {
                NSLog("BlueNudge: could not schedule notification: \(error)")
            }
        }
    }

    /// Re-delivers a notification's content after `minutes`.
    static func snooze(content: UNNotificationContent, minutes: Int) async {
        guard let copy = content.mutableCopy() as? UNMutableNotificationContent else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
        let request = UNNotificationRequest(identifier: snoozePrefix + UUID().uuidString, content: copy, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

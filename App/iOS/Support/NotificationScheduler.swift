import Foundation
import UserNotifications
import ReminderCore

/// Schedules the local notifications that drive tap-to-send reminders.
///
/// iOS allows 64 pending notifications per app, so only the next 60 occurrences
/// are scheduled; the list is rebuilt whenever the app opens or data changes.
@MainActor
enum NotificationScheduler {
    static let categoryID = "SEND_REMINDER"
    static let sendAction = "SEND_NOW"
    static let snoozeAction = "SNOOZE_15"
    private static let occurrencePrefix = "occ|"
    private static let snoozePrefix = "snooze|"
    private static let maxScheduled = 60

    static func registerCategories() {
        let send = UNNotificationAction(identifier: sendAction, title: "Send now", options: [.foreground])
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "Remind me in 15 minutes", options: [])
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [send, snooze],
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

    /// Replaces all scheduled tap-to-send notifications with the next occurrences.
    static func reschedule(using repository: Repository) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        await updateBadge(using: repository)
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }

        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(occurrencePrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        let reminders = repository.reminders()
        let directory = repository.recipientDirectory()
        var reminderByID: [UUID: Reminder] = [:]
        for reminder in reminders { reminderByID[reminder.id] = reminder }

        let upcoming = DuePlanner.upcoming(
            reminders: reminders.map(\.plannerValue),
            method: .tapToSend,
            after: Date(),
            horizon: 60 * 86_400,
            limit: maxScheduled
        )

        for item in upcoming {
            guard let reminder = reminderByID[item.reminderID] else { continue }
            let names = reminder.recipientIDs
                .compactMap { directory[$0] }
                .filter { !$0.optedOut && !$0.handle.isEmpty }
                .map { $0.name.isEmpty ? HandleNormalizer.displayFormat($0.handle) : $0.name }
            guard !names.isEmpty else { continue }

            let content = UNMutableNotificationContent()
            content.title = reminder.displayTitle
            content.body = "Time to message \(ListFormatter.localizedString(byJoining: names)). Tap to send."
            content.sound = .default
            content.categoryIdentifier = categoryID
            content.threadIdentifier = reminder.id.uuidString
            content.userInfo = [
                "reminderID": reminder.id.uuidString,
                "occurrence": item.occurrence.timeIntervalSince1970,
            ]

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

    /// App icon badge = tap-to-send messages waiting right now.
    static func updateBadge(using repository: Repository) async {
        let due = repository.plan(method: .tapToSend, lookback: SendQueue.lookback, grace: SendQueue.lookback).toSend.count
        try? await UNUserNotificationCenter.current().setBadgeCount(due)
    }
}

import Foundation
import SwiftUI
import ReminderCore
#if canImport(AlarmKit)
import AlarmKit
#endif

/// Schedules "Alarm" reminders with AlarmKit (iOS 26+): they ring like the Clock
/// app's alarms, through Silent mode and Focus, until stopped. Like notifications,
/// the next few occurrences are scheduled and refreshed whenever the app opens.
@MainActor
enum AlarmScheduler {
    enum Access: Equatable {
        case unsupported, notDetermined, authorized, denied
    }

    /// AlarmKit limits how many alarms an app can have scheduled.
    static let maxScheduled = 25

    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    static var access: Access {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return .authorized
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }
        }
        #endif
        return .unsupported
    }

    @discardableResult
    static func requestAccess() async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                return try await AlarmManager.shared.requestAuthorization() == .authorized
            } catch {
                NSLog("BlueNudge: alarm authorization failed: \(error)")
            }
        }
        #endif
        return false
    }

    /// Replaces every scheduled alarm with the next occurrences of "Alarm" reminders.
    static func reschedule(using repository: Repository) async {
        #if canImport(AlarmKit)
        guard #available(iOS 26.0, *), access == .authorized, !DemoMode.isEnabled else { return }
        let manager = AlarmManager.shared
        for alarm in (try? manager.alarms) ?? [] {
            try? manager.cancel(id: alarm.id)
        }

        let reminders = repository.reminders()
        var byID: [UUID: Reminder] = [:]
        for reminder in reminders { byID[reminder.id] = reminder }
        let settings = repository.existingSettings()?.renderSettings() ?? RenderSettings()
        let upcoming = DuePlanner.upcoming(
            reminders: reminders.map(\.plannerValue),
            method: .alarm,
            after: Date(),
            horizon: 60 * 86_400,
            limit: maxScheduled
        )
        for item in upcoming {
            guard let reminder = byID[item.reminderID] else { continue }
            let text = TemplateRenderer.render(
                template: reminder.messageTemplate,
                recipientName: "",
                reminderTitle: reminder.title,
                occurrence: item.occurrence,
                timeZone: reminder.schedule.timeZone,
                settings: settings
            )
            do {
                _ = try await manager.schedule(id: UUID(), configuration: configuration(text: text, reminderID: reminder.id, at: item.occurrence))
            } catch AlarmManager.AlarmError.maximumLimitReached {
                break
            } catch {
                NSLog("BlueNudge: could not schedule an alarm: \(error)")
            }
        }
        #endif
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private static func configuration(text: String, reminderID: UUID, at date: Date) -> AlarmManager.AlarmConfiguration<ReminderAlarmMetadata> {
        let title = LocalizedStringResource("\(String(text.prefix(80)))")
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: title)
        } else {
            alert = AlarmPresentation.Alert(
                title: title,
                stopButton: AlarmButton(text: "Done", textColor: .white, systemImageName: "checkmark")
            )
        }
        let attributes = AlarmAttributes<ReminderAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert, countdown: nil, paused: nil),
            metadata: ReminderAlarmMetadata(reminderID: reminderID.uuidString),
            tintColor: .accentColor
        )
        return .alarm(schedule: .fixed(date), attributes: attributes)
    }
    #endif
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct ReminderAlarmMetadata: AlarmMetadata {
    var reminderID: String
}
#endif

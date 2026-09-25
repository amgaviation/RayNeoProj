import Foundation
import SwiftData
import ReminderCore

/// Demo mode fills an in-memory store with sample reminders and history, for
/// screenshots and App Store previews. It never touches real data and is only
/// reachable in Debug builds:
///
///     -BlueNudgeDemo YES [-BlueNudgeScreen today|reminders|editor|activity|settings|texts|onboarding]
///     -BlueNudgeSnapshot <folder>   (Mac relay: write window images there, then quit)
enum DemoMode {
    static var isEnabled: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "BlueNudgeDemo")
        #else
        return false
        #endif
    }

    static var screen: String {
        UserDefaults.standard.string(forKey: "BlueNudgeScreen") ?? "today"
    }

    static var snapshotDirectory: String? {
        guard isEnabled else { return nil }
        return UserDefaults.standard.string(forKey: "BlueNudgeSnapshot")
    }
}

@MainActor
enum DemoData {
    static let editorReminderTitle = "Drink water"
    static let relayName = "Home Mac mini"

    /// The iPhone shows reminders texted by BlueNudge's server, alarms and
    /// notifications; the Mac relay shows reminders it texts itself.
    enum Style {
        case iPhone, mac

        static var current: Style {
            #if os(iOS)
            return .iPhone
            #else
            return .mac
            #endif
        }
    }

    static func seed(into context: ModelContext, style: Style = .current) {
        let repository = Repository(context: context)
        let now = Date()
        let calendar = Calendar.current
        let zone = TimeZone.current.identifier
        let texted: DeliveryMethod = style == .iPhone ? .sms : .relay

        func at(_ hour: Int, _ minute: Int = 0, daysFromToday days: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        let settings = SharedSettings()
        settings.defaultCountryCode = "1"
        settings.defaultMethod = texted
        context.insert(settings)

        let me = Recipient(name: "Me", rawHandle: "(512) 555-0142", handle: "+15125550142")
        context.insert(me)

        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        func reminder(
            _ title: String,
            _ message: String,
            _ schedule: Schedule,
            _ method: DeliveryMethod? = nil,
            activeSince: Date? = nil
        ) -> Reminder {
            let created = Reminder(title: title, messageTemplate: message, schedule: schedule, recipientIDs: [me.id], method: method ?? texted)
            created.activeSince = activeSince ?? weekAgo
            created.createdAt = weekAgo
            context.insert(created)
            return created
        }

        _ = reminder(
            "Take vitamins",
            "Take your vitamins 💊",
            Schedule(frequency: .daily, start: at(8, 0, daysFromToday: -10), timeZoneIdentifier: zone)
        )
        _ = reminder(
            editorReminderTitle,
            "Time for a glass of water 💧",
            Schedule(
                frequency: .hourly,
                start: at(9, 0, daysFromToday: -10),
                interval: 2,
                timeZoneIdentifier: zone,
                activeMinutes: (9 * 60)...(21 * 60)
            )
        )
        _ = reminder(
            "Call Mom",
            "Call Mom ☎️ It's Sunday!",
            Schedule(frequency: .weekly, start: at(18, 0, daysFromToday: -14), weekdays: [1], timeZoneIdentifier: zone)
        )
        _ = reminder(
            "Credit card",
            "Credit card payment is due {date}. Pay it today 💳",
            Schedule(frequency: .monthly, start: at(9, 0, daysFromToday: 5), timeZoneIdentifier: zone)
        )
        _ = reminder(
            "Dentist",
            "Dentist at 10:30 today. Leave by 10:00 🦷",
            Schedule(frequency: .once, start: at(8, 30, daysFromToday: 1), timeZoneIdentifier: zone)
        )
        _ = reminder(
            "Trash night",
            "Trash and recycling go out tonight 🗑️",
            Schedule(frequency: .weekly, start: at(20, 0, daysFromToday: -14), weekdays: [4], timeZoneIdentifier: zone),
            .notification,
            activeSince: now.addingTimeInterval(-300)
        )
        let snoozed = reminder(
            "Snoozed: Call the pharmacy",
            "Call the pharmacy about the refill",
            Schedule(frequency: .once, start: now.addingTimeInterval(20 * 60).roundedUpToMinute(), timeZoneIdentifier: zone),
            activeSince: now.addingTimeInterval(-60)
        )
        snoozed.notes = Reminder.snoozeNote
        let paused = reminder(
            "Stand up and stretch",
            "Stand up and stretch for a minute 🧘",
            Schedule(frequency: .hourly, start: at(10, 0, daysFromToday: -10), timeZoneIdentifier: zone, activeMinutes: 600...1_020)
        )
        paused.isActive = false
        if style == .iPhone {
            _ = reminder(
                "Evening medication",
                "Take your evening medication 💊",
                Schedule(frequency: .daily, start: at(21, 0, daysFromToday: -10), timeZoneIdentifier: zone),
                .alarm
            )
        }
        repository.save()

        guard style == .mac else { return }

        // History: every text the relay would have sent over the last few days.
        let history = repository.plan(method: .relay, lookback: 3 * 86_400, grace: 3 * 86_400, now: now)
        for message in history.toSend + history.missed {
            let record = repository.record(message, status: .delivered, channel: .relay, deviceName: relayName)
            record.createdAt = message.occurrence.addingTimeInterval(1)
            record.sentAt = message.occurrence.addingTimeInterval(2)
            record.deliveredAt = message.occurrence.addingTimeInterval(4)
            record.serviceUsed = "iMessage"
        }

        let heartbeat = RelayHeartbeat(deviceID: "demo-relay", deviceName: relayName)
        heartbeat.lastSeen = now.addingTimeInterval(-45)
        heartbeat.appVersion = DeviceInfo.appVersion
        heartbeat.sentLast24h = history.toSend.filter { now.timeIntervalSince($0.occurrence) < 86_400 }.count
        heartbeat.lastSendAt = history.toSend.last?.occurrence
        context.insert(heartbeat)

        repository.save()
    }

    /// iPhone demo: what BlueNudge's server texted over the last few days,
    /// newest first.
    static func texts(repository: Repository, now: Date = Date()) -> [RemoteText] {
        let history = repository.plan(method: .sms, lookback: 3 * 86_400, grace: 3 * 86_400, now: now)
        let sent = (history.toSend + history.missed).sorted { $0.occurrence < $1.occurrence }
        let texts = sent.enumerated().map { index, message in
            RemoteText(
                id: index + 1,
                title: message.reminderTitle,
                body: message.text,
                fireAt: message.occurrence,
                status: "delivered",
                error: nil,
                sentAt: message.occurrence.addingTimeInterval(2),
                source: "app"
            )
        }
        return Array(texts.reversed())
    }
}

private extension Date {
    func roundedUpToMinute() -> Date {
        let seconds = timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.up) * 60)
    }
}

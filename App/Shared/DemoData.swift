import Foundation
import SwiftData
import ReminderCore

/// Demo mode fills an in-memory store with sample people, reminders and history,
/// for screenshots and App Store previews. It never touches real data and is
/// only reachable in Debug builds:
///
///     -BlueNudgeDemo YES [-BlueNudgeScreen today|queue|reminders|editor|people|activity|settings|onboarding]
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
    static let editorReminderTitle = "Weekly team check-in"
    static let relayName = "Office Mac mini"

    static func seed(into context: ModelContext) {
        let repository = Repository(context: context)
        let now = Date()
        let calendar = Calendar.current
        let zone = TimeZone.current.identifier

        func at(_ hour: Int, _ minute: Int = 0, daysFromToday days: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        let settings = SharedSettings()
        settings.senderName = "Coastal Dental"
        settings.defaultCountryCode = "1"
        settings.defaultMethod = .relay
        settings.appendOptOutFooter = true
        context.insert(settings)

        func person(_ name: String, _ raw: String, _ handle: String) -> Recipient {
            let recipient = Recipient(name: name, rawHandle: raw, handle: handle)
            context.insert(recipient)
            return recipient
        }
        let maria = person("Maria Lopez", "(512) 555-0142", "+15125550142")
        let james = person("James Carter", "(512) 555-0187", "+15125550187")
        let priya = person("Priya Shah", "priya.shah@icloud.com", "priya.shah@icloud.com")
        let daniel = person("Daniel Kim", "(737) 555-0110", "+17375550110")
        let leo = person("Leo Park", "(415) 555-0131", "+14155550131")
        let olivia = person("Olivia Brooks", "(512) 555-0199", "+15125550199")
        olivia.setOptedOut(true, source: "reply")
        let sam = person("Sam Rivera", "(206) 555-0123", "+12065550123")
        let ana = person("Ana Torres", "(305) 555-0168", "+13055550168")

        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        func reminder(
            _ title: String,
            _ template: String,
            _ schedule: Schedule,
            _ people: [Recipient],
            _ method: DeliveryMethod,
            activeSince: Date
        ) -> Reminder {
            let created = Reminder(title: title, messageTemplate: template, schedule: schedule, recipientIDs: people.map(\.id), method: method)
            created.activeSince = activeSince
            created.createdAt = weekAgo
            context.insert(created)
            return created
        }

        _ = reminder(
            "Appointment reminder",
            "Hi {first_name}, this is {sender} reminding you of your cleaning on {weekday}, {date} at {time}. Reply C to confirm.",
            Schedule(frequency: .once, start: at(10, 30, daysFromToday: 1), timeZoneIdentifier: zone),
            [maria],
            .relay,
            activeSince: weekAgo
        )
        _ = reminder(
            editorReminderTitle,
            "Morning {first_name}! Team check-in at {time} today. Agenda is in the shared folder.",
            Schedule(frequency: .weekly, start: at(9, 0, daysFromToday: -14), weekdays: [2, 4, 6], timeZoneIdentifier: zone),
            [james, daniel, priya, leo],
            .relay,
            activeSince: weekAgo
        )
        _ = reminder(
            "Invoice follow-up",
            "Hi {first_name}, a quick nudge on the invoice sent last week. Let me know if you have any questions. – {sender}",
            Schedule(frequency: .weekly, start: at(15, 0, daysFromToday: -12), interval: 2, weekdays: [6], timeZoneIdentifier: zone),
            [priya],
            .relay,
            activeSince: weekAgo
        )
        _ = reminder(
            "Rent reminder",
            "Hi {first_name}, friendly reminder that rent is due {date}. Thank you!",
            Schedule(frequency: .monthly, start: at(9, 0, daysFromToday: 3), timeZoneIdentifier: zone),
            [sam],
            .tapToSend,
            activeSince: now.addingTimeInterval(-300)
        )
        _ = reminder(
            "Order ready for pickup",
            "Hi {first_name}, your order is ready for pickup today. See you soon!",
            Schedule(frequency: .once, start: now.addingTimeInterval(-20 * 60), timeZoneIdentifier: zone),
            [ana, sam],
            .tapToSend,
            activeSince: now.addingTimeInterval(-30 * 60)
        )
        _ = reminder(
            "Evening medication",
            "Time for your evening meds, {first_name} 💊",
            Schedule(frequency: .daily, start: at(20, 0, daysFromToday: -3), timeZoneIdentifier: zone),
            [daniel],
            .tapToSend,
            activeSince: now.addingTimeInterval(-300)
        )
        let paused = reminder(
            "Holiday hours",
            "Hi {first_name}, {sender} is closed Monday for the holiday.",
            Schedule(frequency: .yearly, start: at(9, 0, daysFromToday: 40), timeZoneIdentifier: zone),
            [maria, james, priya],
            .relay,
            activeSince: weekAgo
        )
        paused.isActive = false
        repository.save()

        // History: everything the relay would have sent over the last few days.
        let history = repository.plan(method: .relay, lookback: 4 * 86_400, grace: 4 * 86_400, now: now)
        for message in history.toSend + history.missed {
            let record = repository.record(message, status: .delivered, channel: .relay, deviceName: relayName)
            record.createdAt = message.occurrence.addingTimeInterval(1)
            record.sentAt = message.occurrence.addingTimeInterval(2)
            record.deliveredAt = message.occurrence.addingTimeInterval(6)
            record.serviceUsed = "iMessage"
            if message.recipientID == leo.id {
                // An Android number: iMessage fails, the relay resends as SMS.
                record.status = .sent
                record.serviceUsed = "SMS"
                record.deliveredAt = nil
                record.errorMessage = "iMessage wasn't delivered, resent as SMS."
            }
        }
        for message in history.optedOut {
            let record = repository.record(message, status: .optedOut, channel: .relay, deviceName: relayName)
            record.createdAt = message.occurrence.addingTimeInterval(1)
        }

        // A STOP reply the relay picked up.
        let stop = PlannedMessage(
            key: "optout|demo|1",
            reminderID: olivia.id,
            recipientID: olivia.id,
            occurrence: now.addingTimeInterval(-26 * 3_600),
            reminderTitle: "Opted out by reply",
            recipientName: olivia.name,
            handle: olivia.handle,
            service: .auto,
            text: "STOP"
        )
        let stopRecord = repository.record(stop, status: .optedOut, channel: .relay, deviceName: relayName,
                                           error: "They replied “STOP” and won't get further reminders.")
        stopRecord.reminderID = nil
        stopRecord.createdAt = stop.occurrence

        // A tap-to-send reminder sent from the iPhone last week.
        let rent = PlannedMessage(
            key: "demo|rent|1",
            reminderID: UUID(),
            recipientID: sam.id,
            occurrence: now.addingTimeInterval(-6 * 86_400),
            reminderTitle: "Rent reminder",
            recipientName: sam.name,
            handle: sam.handle,
            service: .auto,
            text: "Hi Sam, friendly reminder that rent is due soon. Thank you!"
        )
        let rentRecord = repository.record(rent, status: .sent, channel: .iPhone, deviceName: "iPhone")
        rentRecord.createdAt = rent.occurrence.addingTimeInterval(40)
        rentRecord.sentAt = rentRecord.createdAt

        let heartbeat = RelayHeartbeat(deviceID: "demo-relay", deviceName: relayName)
        heartbeat.lastSeen = now.addingTimeInterval(-45)
        heartbeat.appVersion = DeviceInfo.appVersion
        heartbeat.sentLast24h = history.toSend.filter { now.timeIntervalSince($0.occurrence) < 86_400 }.count
        heartbeat.lastSendAt = history.toSend.last?.occurrence
        context.insert(heartbeat)

        repository.save()
    }
}

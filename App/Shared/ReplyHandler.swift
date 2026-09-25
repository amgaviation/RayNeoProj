import Foundation
import SwiftData
import ReminderCore

/// Acts on a reply to a reminder text: SNOOZE schedules the last text again,
/// STOP pauses texts, START resumes them, DONE is noted. Only replies from the
/// number the reminders go to count. Sending the confirmation is up to the
/// caller (the Mac relay), so this stays testable.
@MainActor
struct ReplyHandler {
    struct Reply {
        let rowID: Int64
        let handle: String
        let text: String
        let date: Date
    }

    enum Action: Equatable {
        case snoozed(title: String, until: Date)
        case nothingToSnooze
        case paused
        case resumed
        case done(title: String?)
        /// Not from you, not a command, turned off in settings, or no change.
        case ignored
    }

    struct Outcome: Equatable {
        var action: Action
        /// Text to send back, when replies are confirmed.
        var confirmation: String?
        /// A line for the relay's event log.
        var logLine: String?

        static let ignored = Outcome(action: .ignored)
    }

    /// How far back to look for the text a SNOOZE refers to.
    static let snoozeLookback: TimeInterval = 24 * 3_600

    let repository: Repository
    let settings: SharedSettings
    let deviceName: String

    func handle(_ reply: Reply, now: Date = Date()) -> Outcome {
        guard let command = ReplyParser.parse(reply.text) else { return .ignored }
        let handle = HandleNormalizer.normalize(reply.handle, defaultCountryCode: settings.defaultCountryCode)
            ?? reply.handle.lowercased()
        let senders = repository.recipients().filter { $0.handle == handle }
        guard !senders.isEmpty else { return .ignored }

        switch command {
        case .snooze(let minutes):
            guard settings.honorSnoozeReplies else { return .ignored }
            return snooze(minutes: minutes, handle: handle, reply: reply, now: now)
        case .pause:
            guard settings.honorOptOutReplies else { return .ignored }
            return pause(senders, handle: handle, reply: reply)
        case .resume:
            guard settings.honorOptOutReplies else { return .ignored }
            return resume(senders, reply: reply)
        case .done:
            let title = lastText(to: handle, before: reply.date, now: now)?.reminderTitle
            let line = title.map { "You marked “\($0)” done." } ?? "You replied “\(reply.text)”."
            return Outcome(action: .done(title: title), logLine: line)
        }
    }

    // MARK: Commands

    private func snooze(minutes: Int, handle: String, reply: Reply, now: Date) -> Outcome {
        // A SNOOZE that sat unread while the Mac was off would fire at a
        // surprising time, so old ones are dropped.
        let maxAge = TimeInterval(max(settings.graceMinutes, 10) * 60)
        guard now.timeIntervalSince(reply.date) <= maxAge else {
            return Outcome(action: .ignored, logLine: "Ignored an old snooze reply (“\(reply.text)”).")
        }
        guard let last = lastText(to: handle, before: reply.date, now: now) else {
            return Outcome(
                action: .nothingToSnooze,
                confirmation: confirm("There's nothing to snooze right now."),
                logLine: "Snooze reply, but no recent text to snooze."
            )
        }
        let title = Self.snoozeTitle(for: last.reminderTitle)
        let message = Self.withoutFooter(last.messageText, footer: settings.optOutFooterText)
        let base = max(now, reply.date)
        let reminder = repository.addOneTimeReminder(
            title: title,
            message: message,
            at: base.addingTimeInterval(TimeInterval(minutes * 60)),
            method: .relay,
            isSnooze: true,
            now: now
        )
        let when = WhenPhrase.describe(reminder.schedule.start, now: now)
        return Outcome(
            action: .snoozed(title: title, until: reminder.schedule.start),
            confirmation: confirm("Okay, I'll text you again \(when)."),
            logLine: "Snoozed “\(last.reminderTitle)” until \(reminder.schedule.start.formatted(date: .omitted, time: .shortened))."
        )
    }

    private func pause(_ senders: [Recipient], handle: String, reply: Reply) -> Outcome {
        let active = senders.filter { !$0.optedOut }
        guard let first = active.first else { return .ignored }
        for recipient in active {
            recipient.setOptedOut(true, source: "reply")
        }
        // Shows in Activity so it's clear why texts stopped.
        let entry = PlannedMessage(
            key: "reply|\(deviceName)|\(reply.rowID)",
            reminderID: first.id,
            recipientID: first.id,
            occurrence: reply.date,
            reminderTitle: "Texts paused",
            recipientName: first.name,
            handle: handle,
            service: .auto,
            text: reply.text
        )
        let record = repository.record(entry, status: .optedOut, channel: .relay, deviceName: deviceName,
                                       error: "You replied “\(reply.text)”. Reply START to turn texts back on.")
        record.reminderID = nil
        repository.save()
        let confirmation = settings.optOutConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(
            action: .paused,
            confirmation: confirmation.isEmpty ? nil : confirm(confirmation),
            logLine: "Texts paused by your reply “\(reply.text)”."
        )
    }

    private func resume(_ senders: [Recipient], reply: Reply) -> Outcome {
        let paused = senders.filter(\.optedOut)
        guard !paused.isEmpty else { return .ignored }
        for recipient in paused {
            recipient.setOptedOut(false, source: "reply")
        }
        repository.save()
        return Outcome(
            action: .resumed,
            confirmation: confirm("Texts are back on."),
            logLine: "Texts resumed by your reply “\(reply.text)”."
        )
    }

    // MARK: Helpers

    private func confirm(_ text: String) -> String? {
        settings.confirmReplies ? text : nil
    }

    /// The newest reminder text sent to `handle` before the reply arrived.
    private func lastText(to handle: String, before date: Date, now: Date) -> DeliveryRecord? {
        repository.deliveries(since: now.addingTimeInterval(-Self.snoozeLookback))
            .filter { record in
                record.channel == .relay
                    && record.recipientHandle == handle
                    && record.status.countsAsSent
                    && record.reminderID != nil
                    && (record.sentAt ?? record.createdAt) <= date
            }
            .max { ($0.sentAt ?? $0.createdAt) < ($1.sentAt ?? $1.createdAt) }
    }

    static let snoozePrefix = "Snoozed: "

    static func snoozeTitle(for title: String) -> String {
        let base = title.hasPrefix(snoozePrefix) ? String(title.dropFirst(snoozePrefix.count)) : title
        return snoozePrefix + (base.isEmpty ? "Reminder" : base)
    }

    /// The text as it was before the optional line added to every text.
    static func withoutFooter(_ text: String, footer: String) -> String {
        let footer = footer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !footer.isEmpty, text.hasSuffix(footer) else { return text }
        return String(text.dropLast(footer.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// "at 9:40 AM", "tomorrow at 9:00 AM" or "on Fri, Oct 3 at 9:00 AM".
enum WhenPhrase {
    static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        return "on \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) at \(time)"
    }
}

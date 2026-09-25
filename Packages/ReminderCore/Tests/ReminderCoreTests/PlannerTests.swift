import XCTest
@testable import ReminderCore

final class PlannerTests: XCTestCase {
    private let zone = "America/Chicago"
    private let settings = RenderSettings(senderName: "Dana", locale: Locale(identifier: "en_US"))

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    private let alice = PlannerRecipient(id: UUID(), name: "Alice Smith", handle: "+15551230001", optedOut: false)
    private let bob = PlannerRecipient(id: UUID(), name: "Bob", handle: "bob@example.com", optedOut: false)

    private func reminder(
        start: String,
        frequency: Schedule.Frequency = .daily,
        recipients: [PlannerRecipient],
        method: DeliveryMethod = .relay,
        active: Bool = true,
        activeSince: String = "2026-01-01 00:00"
    ) -> PlannerReminder {
        PlannerReminder(
            id: UUID(),
            title: "Standup",
            template: "Hi {first_name}, {title} at {time}. – {sender}",
            schedule: Schedule(frequency: frequency, start: date(start), timeZoneIdentifier: zone),
            recipientIDs: recipients.map(\.id),
            method: method,
            isActive: active,
            activeSince: date(activeSince)
        )
    }

    private var directory: [UUID: PlannerRecipient] {
        [alice.id: alice, bob.id: bob]
    }

    func testDueMessagesAreRenderedPerRecipient() {
        let r = reminder(start: "2026-10-01 09:00", recipients: [alice, bob])
        let plan = DuePlanner.plan(
            reminders: [r],
            recipients: directory,
            method: .relay,
            alreadyHandled: [],
            windowStart: date("2026-10-05 08:00"),
            now: date("2026-10-05 09:01"),
            grace: 3_600,
            settings: settings
        )
        XCTAssertEqual(plan.toSend.count, 2)
        XCTAssertEqual(plan.toSend.map(\.handle).sorted(), ["+15551230001", "bob@example.com"])
        let aliceText = plan.toSend.first { $0.recipientID == alice.id }?.text
        XCTAssertEqual(aliceText, "Hi Alice, Standup at 9:00 AM. – Dana")
        XCTAssertTrue(plan.missed.isEmpty)
    }

    func testAlreadyHandledKeysAreSkipped() {
        let r = reminder(start: "2026-10-01 09:00", recipients: [alice, bob])
        let key = OccurrenceKey.make(reminderID: r.id, recipientID: alice.id, occurrence: date("2026-10-05 09:00"))
        let plan = DuePlanner.plan(
            reminders: [r],
            recipients: directory,
            method: .relay,
            alreadyHandled: [key],
            windowStart: date("2026-10-05 08:00"),
            now: date("2026-10-05 09:01"),
            grace: 3_600,
            settings: settings
        )
        XCTAssertEqual(plan.toSend.map(\.recipientID), [bob.id])
    }

    func testOccurrencesPastGraceAreMissed() {
        let r = reminder(start: "2026-10-01 09:00", recipients: [alice])
        let plan = DuePlanner.plan(
            reminders: [r],
            recipients: directory,
            method: .relay,
            alreadyHandled: [],
            windowStart: date("2026-10-04 00:00"),
            now: date("2026-10-05 12:00"),
            grace: 3_600,
            settings: settings
        )
        // 10-04 09:00 and 10-05 09:00 are both more than an hour old.
        XCTAssertEqual(plan.missed.count, 2)
        XCTAssertTrue(plan.toSend.isEmpty)
    }

    func testOptedOutAndUnreachableRecipients() {
        var optedOut = alice
        optedOut.optedOut = true
        let nobody = PlannerRecipient(id: UUID(), name: "No Number", handle: "", optedOut: false)
        let r = reminder(start: "2026-10-01 09:00", recipients: [optedOut, nobody])
        let plan = DuePlanner.plan(
            reminders: [r],
            recipients: [optedOut.id: optedOut, nobody.id: nobody],
            method: .relay,
            alreadyHandled: [],
            windowStart: date("2026-10-05 08:00"),
            now: date("2026-10-05 09:05"),
            grace: 3_600,
            settings: settings
        )
        XCTAssertEqual(plan.optedOut.count, 1)
        XCTAssertEqual(plan.unreachable.count, 1)
        XCTAssertTrue(plan.toSend.isEmpty)
    }

    func testActiveSinceSuppressesEarlierOccurrences() {
        let r = reminder(start: "2026-10-01 09:00", recipients: [alice], activeSince: "2026-10-05 09:30")
        let plan = DuePlanner.plan(
            reminders: [r],
            recipients: directory,
            method: .relay,
            alreadyHandled: [],
            windowStart: date("2026-10-05 00:00"),
            now: date("2026-10-05 09:45"),
            grace: 86_400,
            settings: settings
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testMethodAndActiveFilters() {
        let tap = reminder(start: "2026-10-01 09:00", recipients: [alice], method: .notification)
        let paused = reminder(start: "2026-10-01 09:00", recipients: [alice], active: false)
        let plan = DuePlanner.plan(
            reminders: [tap, paused],
            recipients: directory,
            method: .relay,
            alreadyHandled: [],
            windowStart: date("2026-10-05 08:00"),
            now: date("2026-10-05 09:05"),
            grace: 3_600,
            settings: settings
        )
        XCTAssertTrue(plan.isEmpty)

        let tapPlan = DuePlanner.plan(
            reminders: [tap, paused],
            recipients: directory,
            method: .notification,
            alreadyHandled: [],
            windowStart: date("2026-10-05 08:00"),
            now: date("2026-10-05 09:05"),
            grace: 3_600,
            settings: settings
        )
        XCTAssertEqual(tapPlan.toSend.count, 1)
    }

    func testDuplicateRecipientIDsSendOnce() {
        var r = reminder(start: "2026-10-01 09:00", recipients: [alice])
        r.recipientIDs = [alice.id, alice.id]
        let plan = DuePlanner.plan(
            reminders: [r],
            recipients: directory,
            method: .relay,
            alreadyHandled: [],
            windowStart: date("2026-10-05 08:00"),
            now: date("2026-10-05 09:05"),
            grace: 3_600,
            settings: settings
        )
        XCTAssertEqual(plan.toSend.count, 1)
    }

    func testUpcomingAcrossReminders() {
        let a = reminder(start: "2026-10-01 09:00", recipients: [alice])
        let b = reminder(start: "2026-10-01 08:00", recipients: [bob], method: .notification)
        let items = DuePlanner.upcoming(
            reminders: [a, b],
            method: nil,
            after: date("2026-10-05 08:30"),
            horizon: 86_400,
            limit: 3
        )
        XCTAssertEqual(items.map(\.occurrence), [date("2026-10-05 09:00"), date("2026-10-06 08:00")])

        let tapOnly = DuePlanner.upcoming(
            reminders: [a, b],
            method: .notification,
            after: date("2026-10-05 08:30"),
            horizon: 3 * 86_400,
            limit: 10
        )
        XCTAssertEqual(tapOnly.count, 3)
        XCTAssertTrue(tapOnly.allSatisfy { $0.reminderID == b.id })
    }

    func testOccurrenceKeyRoundTrip() {
        let reminderID = UUID()
        let recipientID = UUID()
        let occurrence = Date(timeIntervalSince1970: 1_790_000_000)
        let key = OccurrenceKey.make(reminderID: reminderID, recipientID: recipientID, occurrence: occurrence)
        let parsed = OccurrenceKey.parse(key)
        XCTAssertEqual(parsed?.reminderID, reminderID)
        XCTAssertEqual(parsed?.recipientID, recipientID)
        XCTAssertEqual(parsed?.occurrence, occurrence)
        XCTAssertNil(OccurrenceKey.parse("garbage"))
    }
}

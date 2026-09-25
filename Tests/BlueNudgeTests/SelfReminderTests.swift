import SwiftData
import XCTest
import ReminderCore

/// "Texts go to" bookkeeping, one-time reminders, and what the relay does with
/// replies (SNOOZE, STOP, START, DONE), against an in-memory store.
@MainActor
final class SelfReminderTests: XCTestCase {
    private var container: ModelContainer?
    private let myNumber = "+15125550142"

    private func makeRepository() throws -> Repository {
        let schema = Schema(AppSchema.models)
        let configuration = ModelConfiguration(
            "SelfReminderTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, migrationPlan: nil, configurations: [configuration])
        self.container = container
        let repository = Repository(context: container.mainContext)
        repository.settings().defaultCountryCode = "1"
        repository.save()
        return repository
    }

    /// A text the relay sent `secondsAgo` before `now`.
    @discardableResult
    private func sentText(
        _ repository: Repository,
        title: String = "Take vitamins",
        text: String = "Take your vitamins 💊",
        handle: String? = nil,
        secondsAgo: TimeInterval = 120,
        now: Date
    ) -> DeliveryRecord {
        let message = PlannedMessage(
            key: "k-\(UUID().uuidString)",
            reminderID: UUID(),
            recipientID: repository.me()?.id ?? UUID(),
            occurrence: now.addingTimeInterval(-secondsAgo),
            reminderTitle: title,
            recipientName: "Me",
            handle: handle ?? myNumber,
            service: .auto,
            text: text
        )
        let record = repository.record(message, status: .delivered, channel: .relay, deviceName: "Mac")
        record.sentAt = now.addingTimeInterval(-secondsAgo)
        repository.save()
        return record
    }

    private func reply(_ text: String, from handle: String? = nil, at date: Date, rowID: Int64 = 1) -> ReplyHandler.Reply {
        ReplyHandler.Reply(rowID: rowID, handle: handle ?? myNumber, text: text, date: date)
    }

    private func handler(_ repository: Repository) -> ReplyHandler {
        ReplyHandler(repository: repository, settings: repository.settings(), deviceName: "Mac")
    }

    // MARK: Texts go to

    func testSettingMyNumberAssignsRemindersWithoutOne() throws {
        let repository = try makeRepository()
        XCTAssertNil(repository.me())
        let reminder = Reminder(
            title: "Water",
            messageTemplate: "Drink water",
            schedule: Schedule(frequency: .daily, start: Date()),
            recipientIDs: [],
            method: .relay
        )
        repository.context.insert(reminder)
        repository.save()

        XCTAssertNil(repository.setMyHandle("not a number"))
        let me = try XCTUnwrap(repository.setMyHandle("(512) 555-0142"))
        XCTAssertEqual(me.handle, myNumber)
        XCTAssertEqual(me.rawHandle, "(512) 555-0142")
        XCTAssertEqual(reminder.recipientIDs, [me.id])

        // Changing it updates the same record.
        let changed = try XCTUnwrap(repository.setMyHandle("Me@iCloud.com"))
        XCTAssertTrue(changed === me)
        XCTAssertEqual(me.handle, "me@icloud.com")
        XCTAssertEqual(repository.recipients().count, 1)
    }

    func testCopiesOfMeFromTwoDevicesCollapse() throws {
        let repository = try makeRepository()
        let first = Recipient(name: "Me", rawHandle: myNumber, handle: myNumber)
        let later = Recipient(name: "Me", rawHandle: myNumber, handle: myNumber)
        later.createdAt = first.createdAt.addingTimeInterval(60)
        repository.context.insert(first)
        repository.context.insert(later)
        let reminder = Reminder(
            title: "Rent",
            messageTemplate: "Rent",
            schedule: Schedule(frequency: .monthly, start: Date()),
            recipientIDs: [later.id],
            method: .relay
        )
        repository.context.insert(reminder)
        repository.save()

        let firstID = first.id
        XCTAssertTrue(repository.me() === first)
        XCTAssertEqual(repository.recipients().count, 1)
        XCTAssertEqual(reminder.recipientIDs, [firstID])
    }

    // MARK: One-time reminders

    func testOneTimeReminderIsTextedOnceANumberIsSet() throws {
        let repository = try makeRepository()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_010)

        let early = repository.addOneTimeReminder(title: "Milk", message: "Buy milk", at: now.addingTimeInterval(600), now: now)
        XCTAssertEqual(early.method, .notification)
        XCTAssertTrue(early.recipientIDs.isEmpty)
        // Rounded up to a whole minute, never early.
        XCTAssertEqual(early.schedule.start.timeIntervalSinceReferenceDate, 800_000_640)
        XCTAssertEqual(early.schedule.frequency, .once)

        let me = try XCTUnwrap(repository.setMyHandle(myNumber))
        let later = repository.addOneTimeReminder(title: "Bread", message: "Buy bread", at: now.addingTimeInterval(600), now: now)
        XCTAssertEqual(later.method, .relay)
        XCTAssertEqual(later.recipientIDs, [me.id])
        XCTAssertFalse(later.isSnooze)
    }

    func testFinishedSnoozesArePrunedAfterADay() throws {
        let repository = try makeRepository()
        let now = Date()
        let old = repository.addOneTimeReminder(title: "Snoozed: A", message: "A", at: now.addingTimeInterval(-2 * 86_400), isSnooze: true, now: now)
        let upcoming = repository.addOneTimeReminder(title: "Snoozed: B", message: "B", at: now.addingTimeInterval(3_600), isSnooze: true, now: now)
        let regular = repository.addOneTimeReminder(title: "C", message: "C", at: now.addingTimeInterval(-2 * 86_400), now: now)
        let upcomingID = upcoming.id
        let regularID = regular.id
        let oldID = old.id

        repository.pruneFinishedSnoozes(now: now)
        let remaining = Set(repository.reminders().map(\.id))
        XCTAssertEqual(remaining, [upcomingID, regularID])
        XCTAssertFalse(remaining.contains(oldID))
    }

    // MARK: Replies

    func testSnoozeTextsTheLastReminderAgain() throws {
        let repository = try makeRepository()
        let me = try XCTUnwrap(repository.setMyHandle(myNumber))
        let now = Date()
        sentText(repository, now: now)

        let outcome = handler(repository).handle(reply("snooze 20", at: now), now: now)
        guard case .snoozed(let title, let until) = outcome.action else {
            return XCTFail("Expected a snooze, got \(outcome.action)")
        }
        XCTAssertEqual(title, "Snoozed: Take vitamins")
        XCTAssertGreaterThanOrEqual(until, now.addingTimeInterval(20 * 60))
        XCTAssertLessThan(until, now.addingTimeInterval(21 * 60))
        XCTAssertTrue(outcome.confirmation?.hasPrefix("Okay, I'll text you again") ?? false)

        let snoozed = try XCTUnwrap(repository.reminders().first { $0.isSnooze })
        XCTAssertEqual(snoozed.messageTemplate, "Take your vitamins 💊")
        XCTAssertEqual(snoozed.method, .relay)
        XCTAssertEqual(snoozed.recipientIDs, [me.id])

        // The relay picks it up when it comes due.
        let plan = repository.plan(method: .relay, lookback: 3_600, grace: 3_600, now: until.addingTimeInterval(30))
        XCTAssertEqual(plan.toSend.map(\.text), ["Take your vitamins 💊"])
        XCTAssertEqual(plan.toSend.first?.handle, myNumber)
    }

    func testSnoozeOfASnoozeKeepsOnePrefixAndDropsTheAddedLine() throws {
        let repository = try makeRepository()
        repository.setMyHandle(myNumber)
        let settings = repository.settings()
        settings.appendOptOutFooter = true
        repository.save()
        let now = Date()
        sentText(repository, title: "Snoozed: Pay rent", text: "Pay rent\n\n\(settings.optOutFooterText)", now: now)

        let outcome = handler(repository).handle(reply("LATER", at: now), now: now)
        guard case .snoozed(let title, _) = outcome.action else {
            return XCTFail("Expected a snooze, got \(outcome.action)")
        }
        XCTAssertEqual(title, "Snoozed: Pay rent")
        XCTAssertEqual(repository.reminders().first { $0.isSnooze }?.messageTemplate, "Pay rent")
    }

    func testSnoozeWithNothingSentSaysSo() throws {
        let repository = try makeRepository()
        repository.setMyHandle(myNumber)
        let now = Date()

        let outcome = handler(repository).handle(reply("Snooze", at: now), now: now)
        XCTAssertEqual(outcome.action, .nothingToSnooze)
        XCTAssertEqual(outcome.confirmation, "There's nothing to snooze right now.")
        XCTAssertTrue(repository.reminders().isEmpty)
    }

    func testRepliesFromOtherNumbersAreIgnored() throws {
        let repository = try makeRepository()
        repository.setMyHandle(myNumber)
        let now = Date()
        sentText(repository, now: now)

        let outcome = handler(repository).handle(reply("STOP", from: "+15550000000", at: now), now: now)
        XCTAssertEqual(outcome, .ignored)
        XCTAssertFalse(try XCTUnwrap(repository.me()).optedOut)
        XCTAssertEqual(handler(repository).handle(reply("snooze", from: "+15550000000", at: now), now: now), .ignored)
        XCTAssertTrue(repository.reminders().isEmpty)
    }

    func testChatterIsIgnored() throws {
        let repository = try makeRepository()
        repository.setMyHandle(myNumber)
        let now = Date()
        sentText(repository, now: now)
        XCTAssertEqual(handler(repository).handle(reply("see you at 5 tomorrow", at: now), now: now), .ignored)
    }

    func testStopPausesAndStartResumes() throws {
        let repository = try makeRepository()
        let me = try XCTUnwrap(repository.setMyHandle(myNumber))
        let now = Date()

        let paused = handler(repository).handle(reply("STOP", at: now), now: now)
        XCTAssertEqual(paused.action, .paused)
        XCTAssertEqual(paused.confirmation, repository.settings().optOutConfirmationText)
        XCTAssertTrue(me.optedOut)
        XCTAssertEqual(me.optOutSource, "reply")
        let log = repository.deliveries(since: now.addingTimeInterval(-60))
        XCTAssertEqual(log.map(\.status), [.optedOut])
        XCTAssertNil(log.first?.reminderID)

        // Already paused: nothing more to do.
        XCTAssertEqual(handler(repository).handle(reply("pause", at: now, rowID: 2), now: now), .ignored)

        let resumed = handler(repository).handle(reply("Start", at: now, rowID: 3), now: now)
        XCTAssertEqual(resumed.action, .resumed)
        XCTAssertEqual(resumed.confirmation, "Texts are back on.")
        XCTAssertFalse(me.optedOut)
    }

    func testPausedTextsAreNotPlanned() throws {
        let repository = try makeRepository()
        let me = try XCTUnwrap(repository.setMyHandle(myNumber))
        let due = Date().addingTimeInterval(-60)
        let reminder = Reminder(
            title: "Water",
            messageTemplate: "Drink water",
            schedule: Schedule(frequency: .once, start: due),
            recipientIDs: [me.id],
            method: .relay
        )
        reminder.activeSince = due.addingTimeInterval(-60)
        repository.context.insert(reminder)
        me.setOptedOut(true, source: "manual")
        repository.save()

        let plan = repository.plan(method: .relay, lookback: 3_600, grace: 3_600)
        XCTAssertTrue(plan.toSend.isEmpty)
        XCTAssertEqual(plan.optedOut.count, 1)
    }

    func testConfirmationsAndCommandsCanBeTurnedOff() throws {
        let repository = try makeRepository()
        repository.setMyHandle(myNumber)
        let settings = repository.settings()
        settings.confirmReplies = false
        repository.save()
        let now = Date()
        sentText(repository, now: now)

        let quiet = handler(repository).handle(reply("snooze 5", at: now), now: now)
        guard case .snoozed = quiet.action else {
            return XCTFail("Expected a snooze, got \(quiet.action)")
        }
        XCTAssertNil(quiet.confirmation)

        settings.honorSnoozeReplies = false
        settings.honorOptOutReplies = false
        XCTAssertEqual(handler(repository).handle(reply("snooze", at: now, rowID: 2), now: now), .ignored)
        XCTAssertEqual(handler(repository).handle(reply("STOP", at: now, rowID: 3), now: now), .ignored)
    }

    func testOldSnoozeRepliesAreDropped() throws {
        let repository = try makeRepository()
        repository.setMyHandle(myNumber)
        let now = Date()
        sentText(repository, secondsAgo: 4 * 3_600, now: now)

        let outcome = handler(repository).handle(reply("snooze", at: now.addingTimeInterval(-3 * 3_600)), now: now)
        XCTAssertEqual(outcome.action, .ignored)
        XCTAssertNotNil(outcome.logLine)
        XCTAssertTrue(repository.reminders().isEmpty)
    }

    func testDoneNamesTheReminder() throws {
        let repository = try makeRepository()
        repository.setMyHandle(myNumber)
        let now = Date()
        sentText(repository, now: now)

        let outcome = handler(repository).handle(reply("Done", at: now), now: now)
        XCTAssertEqual(outcome.action, .done(title: "Take vitamins"))
        XCTAssertNil(outcome.confirmation)
    }

    func testEmailRepliesMatchInAnyCase() throws {
        let repository = try makeRepository()
        repository.setMyHandle("Me@iCloud.com")
        let now = Date()
        sentText(repository, handle: "me@icloud.com", now: now)

        let outcome = handler(repository).handle(reply("snooze", from: "ME@icloud.com", at: now), now: now)
        guard case .snoozed = outcome.action else {
            return XCTFail("Expected a snooze, got \(outcome.action)")
        }
    }

    func testWhenPhrase() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9))!
        let later = now.addingTimeInterval(30 * 60)
        let tomorrow = now.addingTimeInterval(86_400)
        let nextWeek = now.addingTimeInterval(5 * 86_400)
        XCTAssertTrue(WhenPhrase.describe(later, now: now, calendar: calendar).hasPrefix("at "))
        XCTAssertTrue(WhenPhrase.describe(tomorrow, now: now, calendar: calendar).hasPrefix("tomorrow at "))
        XCTAssertTrue(WhenPhrase.describe(nextWeek, now: now, calendar: calendar).hasPrefix("on "))
    }
}

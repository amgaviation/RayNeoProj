import SwiftData
import XCTest
import ReminderCore

/// Exercises the SwiftData layer shared by both apps against an in-memory store.
/// Fetches swallow errors (`try?`), so a predicate SwiftData can't evaluate would
/// otherwise fail silently as "no results"; these tests catch that.
@MainActor
final class RepositoryTests: XCTestCase {
    private var container: ModelContainer?

    private func makeRepository() throws -> Repository {
        let schema = Schema(AppSchema.models)
        let configuration = ModelConfiguration(
            "RepositoryTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, migrationPlan: nil, configurations: [configuration])
        self.container = container
        return Repository(context: container.mainContext)
    }

    private func message(key: String, recipientID: UUID = UUID(), occurrence: Date = Date()) -> PlannedMessage {
        PlannedMessage(
            key: key,
            reminderID: UUID(),
            recipientID: recipientID,
            occurrence: occurrence,
            reminderTitle: "Title",
            recipientName: "Name",
            handle: "+15550000000",
            service: .auto,
            text: "Text"
        )
    }

    func testSettingsIsCreatedOnceAndDuplicatesCollapse() throws {
        let repository = try makeRepository()
        XCTAssertNil(repository.existingSettings())
        let first = repository.settings()
        XCTAssertTrue(repository.settings() === first)

        // A copy made on another device before the first sync.
        let later = SharedSettings()
        later.createdAt = first.createdAt.addingTimeInterval(30)
        repository.context.insert(later)
        repository.save()

        XCTAssertTrue(repository.settings() === first)
        XCTAssertEqual(try repository.context.fetchCount(FetchDescriptor<SharedSettings>()), 1)
        XCTAssertTrue(repository.existingSettings() === first)
    }

    func testLookupsByIDAndHandle() throws {
        let repository = try makeRepository()
        let person = Recipient(name: "Ana Diaz", rawHandle: "(555) 123-4567", handle: "+15551234567")
        repository.context.insert(person)
        let reminder = Reminder(
            title: "Rent",
            messageTemplate: "Rent is due",
            schedule: Schedule(frequency: .monthly, start: Date()),
            recipientIDs: [person.id],
            method: .relay
        )
        repository.context.insert(reminder)
        repository.save()

        XCTAssertTrue(repository.recipient(id: person.id) === person)
        XCTAssertTrue(repository.reminder(id: reminder.id) === reminder)
        XCTAssertNil(repository.recipient(id: UUID()))
        XCTAssertNil(repository.reminder(id: UUID()))
        XCTAssertTrue(repository.recipient(matchingHandle: "555.123.4567", defaultCountryCode: "1") === person)
        XCTAssertEqual(repository.recipientDirectory()[person.id]?.handle, "+15551234567")
    }

    func testPlanSendsOnceThenTreatsTheOccurrenceAsHandled() throws {
        let repository = try makeRepository()
        let person = Recipient(name: "Ana Diaz", rawHandle: "+15551234567", handle: "+15551234567")
        repository.context.insert(person)
        let due = Date().addingTimeInterval(-30 * 60)
        let reminder = Reminder(
            title: "Check-in",
            messageTemplate: "Hi {first_name}",
            schedule: Schedule(frequency: .once, start: due),
            recipientIDs: [person.id],
            method: .relay
        )
        reminder.activeSince = due.addingTimeInterval(-60)
        repository.context.insert(reminder)
        repository.save()

        let plan = repository.plan(method: .relay, lookback: 3_600, grace: 3_600)
        let planned = try XCTUnwrap(plan.toSend.first)
        XCTAssertEqual(plan.toSend.count, 1)
        XCTAssertEqual(planned.text, "Hi Ana")
        XCTAssertTrue(repository.plan(method: .notification, lookback: 3_600, grace: 3_600).toSend.isEmpty)

        repository.record(planned, status: .sent, channel: .relay, deviceName: "Test Mac")
        repository.save()

        XCTAssertTrue(repository.isHandled(planned.key))
        XCTAssertFalse(repository.isHandled("someone-else"))
        XCTAssertTrue(repository.handledKeys(since: due.addingTimeInterval(-1)).contains(planned.key))
        XCTAssertEqual(repository.deliveries(since: due.addingTimeInterval(-1)).count, 1)
        XCTAssertTrue(repository.plan(method: .relay, lookback: 3_600, grace: 3_600).toSend.isEmpty)
    }

    func testRelaySendsAwaitingConfirmation() throws {
        let repository = try makeRepository()
        repository.record(message(key: "sent"), status: .sent, channel: .relay, deviceName: "Mac")
        repository.record(message(key: "sending"), status: .sending, channel: .relay, deviceName: "Mac")
        repository.record(message(key: "delivered"), status: .delivered, channel: .relay, deviceName: "Mac")
        repository.record(message(key: "phone"), status: .sent, channel: .iPhone, deviceName: "iPhone")
        let old = repository.record(message(key: "old"), status: .sent, channel: .relay, deviceName: "Mac")
        old.createdAt = Date().addingTimeInterval(-86_400)
        repository.save()

        let keys = Set(repository.relaySendsAwaitingConfirmation(since: Date().addingTimeInterval(-3_600)).map(\.occurrenceKey))
        XCTAssertEqual(keys, ["sent", "sending"])
    }

    func testDeliveriesForOneRecipient() throws {
        let repository = try makeRepository()
        let id = UUID()
        repository.record(message(key: "mine-1", recipientID: id), status: .sent, channel: .iPhone, deviceName: "iPhone")
        repository.record(message(key: "mine-2", recipientID: id), status: .delivered, channel: .relay, deviceName: "Mac")
        repository.record(message(key: "other", recipientID: UUID()), status: .sent, channel: .relay, deviceName: "Mac")
        repository.save()

        let mine = try repository.context.fetch(Repository.deliveriesDescriptor(recipientID: id, limit: 20))
        XCTAssertEqual(Set(mine.map(\.occurrenceKey)), ["mine-1", "mine-2"])
        let limited = try repository.context.fetch(Repository.deliveriesDescriptor(recipientID: id, limit: 1))
        XCTAssertEqual(limited.count, 1)
    }

    func testHeartbeatLookup() throws {
        let repository = try makeRepository()
        repository.context.insert(RelayHeartbeat(deviceID: "A", deviceName: "Office Mac"))
        repository.context.insert(RelayHeartbeat(deviceID: "B", deviceName: "Home Mac"))
        repository.save()

        XCTAssertEqual(repository.heartbeats(deviceID: "A").map(\.deviceName), ["Office Mac"])
        XCTAssertTrue(repository.heartbeats(deviceID: "C").isEmpty)
        XCTAssertEqual(repository.heartbeats().count, 2)
    }

    func testPruneKeepsRecentRecords() throws {
        let repository = try makeRepository()
        repository.record(message(key: "old", occurrence: Date().addingTimeInterval(-200 * 86_400)), status: .sent, channel: .relay, deviceName: "Mac")
        repository.record(message(key: "new", occurrence: Date()), status: .sent, channel: .relay, deviceName: "Mac")
        repository.save()

        repository.pruneDeliveries(olderThanDays: 180)
        let remaining = try repository.context.fetch(FetchDescriptor<DeliveryRecord>())
        XCTAssertEqual(remaining.map(\.occurrenceKey), ["new"])
    }

    func testDeletingAPersonRemovesThemFromReminders() throws {
        let repository = try makeRepository()
        let ana = Recipient(name: "Ana", rawHandle: "+15551234567", handle: "+15551234567")
        let ben = Recipient(name: "Ben", rawHandle: "+15551234568", handle: "+15551234568")
        repository.context.insert(ana)
        repository.context.insert(ben)
        let reminder = Reminder(
            title: "Standup",
            messageTemplate: "Standup",
            schedule: Schedule(frequency: .daily, start: Date()),
            recipientIDs: [ana.id, ben.id],
            method: .notification
        )
        repository.context.insert(reminder)
        repository.save()

        // Read IDs up front: a deleted model must not be touched after saving.
        let anaID = ana.id
        let benID = ben.id
        repository.delete(ana)
        XCTAssertEqual(reminder.recipientIDs, [benID])
        XCTAssertNil(repository.recipient(id: anaID))
    }

    func testReminderStoresScheduleAndRecipientsAsText() {
        let ids = [UUID(), UUID()]
        let schedule = Schedule(
            frequency: .weekly,
            start: Date(timeIntervalSince1970: 1_790_000_040),
            weekdays: [2, 4],
            end: .after(6),
            timeZoneIdentifier: "America/Chicago"
        )
        let reminder = Reminder(title: "T", messageTemplate: "M", schedule: schedule, recipientIDs: ids, method: .notification)
        XCTAssertEqual(reminder.schedule, schedule)
        XCTAssertEqual(reminder.recipientIDs, ids)
        XCTAssertEqual(reminder.method, .notification)

        reminder.recipientIDs = [ids[1]]
        XCTAssertEqual(reminder.recipientIDsRaw, ids[1].uuidString)
        reminder.scheduleJSON = "not json"
        XCTAssertEqual(reminder.schedule.frequency, .once)
    }

    func testDemoDataIsConsistent() throws {
        let repository = try makeRepository()
        DemoData.seed(into: repository.context, style: .mac)
        let now = Date()

        let me = try XCTUnwrap(repository.me())
        XCTAssertEqual(repository.recipients().count, 1)
        XCTAssertEqual(repository.reminders().count, 8)
        XCTAssertTrue(repository.reminders().allSatisfy { $0.recipientIDs == [me.id] })
        XCTAssertNotNil(repository.existingSettings())
        XCTAssertEqual(repository.heartbeats().count, 1)
        XCTAssertNotNil(repository.reminders().first { $0.title == DemoData.editorReminderTitle })
        XCTAssertTrue(repository.reminders().contains { $0.method == .notification })

        // Every text due in the last day already has a record, so Today shows
        // nothing late.
        let relay = repository.plan(method: .relay, lookback: 86_400, grace: 86_400, now: now)
        XCTAssertTrue(relay.toSend.isEmpty)
        XCTAssertTrue(relay.missed.isEmpty)
        XCTAssertFalse(repository.deliveries(since: now.addingTimeInterval(-7 * 86_400)).isEmpty)
    }

    func testIPhoneDemoDataUsesTextsAlarmsAndNotifications() throws {
        let repository = try makeRepository()
        DemoData.seed(into: repository.context, style: .iPhone)
        let now = Date()

        let methods = Set(repository.reminders().map(\.method))
        XCTAssertEqual(repository.reminders().count, 9)
        XCTAssertEqual(methods, [.sms, .alarm, .notification])
        XCTAssertEqual(repository.existingSettings()?.defaultMethod, .sms)
        let dentist = try XCTUnwrap(repository.reminders().first { $0.title == DemoData.deliveryReminderTitle })
        XCTAssertEqual(dentist.schedule.frequency, .once)
        XCTAssertTrue(repository.heartbeats().isEmpty)
        XCTAssertTrue(repository.deliveries(since: now.addingTimeInterval(-7 * 86_400)).isEmpty)

        let texts = DemoData.texts(repository: repository, now: now)
        XCTAssertFalse(texts.isEmpty)
        XCTAssertEqual(Set(texts.map(\.id)).count, texts.count)
        XCTAssertTrue(texts.allSatisfy { $0.fireAt <= now && $0.status == "delivered" })
        XCTAssertEqual(texts.map(\.fireAt), texts.map(\.fireAt).sorted(by: >))
    }

    func testOptOutBookkeeping() {
        let person = Recipient(name: "Ana", rawHandle: "+15551234567", handle: "+15551234567")
        person.setOptedOut(true, source: "reply")
        XCTAssertTrue(person.optedOut)
        XCTAssertNotNil(person.optedOutAt)
        XCTAssertEqual(person.optOutSource, "reply")
        XCTAssertTrue(person.plannerValue.optedOut)
        person.setOptedOut(false, source: "reply")
        XCTAssertFalse(person.optedOut)
        XCTAssertNil(person.optedOutAt)
        XCTAssertEqual(person.optOutSource, "")
    }
}

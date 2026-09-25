import AppIntents
import Foundation
import ReminderCore

// Shortcuts actions. Together with the built-in "Send Message" action they let a
// Time of Day automation send tap-to-send reminders without a tap:
//   Get Due BlueNudge Messages → Repeat with Each → Send Message → Mark BlueNudge Message Sent

/// One message that is due: who to send it to and what to say.
struct DueMessageEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "BlueNudge Message")
    static let defaultQuery = DueMessageQuery()

    /// The occurrence key, so the message can be found again statelessly.
    let id: String

    @Property(title: "Text")
    var text: String

    @Property(title: "Handle")
    var handle: String

    @Property(title: "Recipient Name")
    var recipientName: String

    @Property(title: "Reminder")
    var reminderTitle: String

    @Property(title: "Due")
    var dueDate: Date

    init(message: PlannedMessage) {
        id = message.key
        text = message.text
        handle = message.handle
        recipientName = message.recipientName
        reminderTitle = message.reminderTitle
        dueDate = message.occurrence
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(recipientName.isEmpty ? handle : recipientName)",
            subtitle: "\(text)"
        )
    }
}

struct DueMessageQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DueMessageEntity] {
        let wanted = Set(identifiers)
        return await IntentData.dueMessages().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [DueMessageEntity] {
        await IntentData.dueMessages()
    }
}

@MainActor
enum IntentData {
    static func dueMessages() -> [DueMessageEntity] {
        let repository = Repository(context: DataStore.shared.mainContext)
        return SendQueue.dueMessages(repository: repository).map(DueMessageEntity.init)
    }

    static func markSent(key: String) -> Bool {
        let repository = Repository(context: DataStore.shared.mainContext)
        guard let message = SendQueue.dueMessages(repository: repository).first(where: { $0.key == key }) else {
            return false
        }
        SendQueue.record(message, status: .sent, channel: .shortcut, repository: repository)
        return true
    }
}

struct GetDueMessagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Due BlueNudge Messages"
    static let description = IntentDescription(
        "Returns the tap-to-send reminder messages that are due now, each with its text and recipient handle. Pair it with Send Message and Mark BlueNudge Message Sent."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<[DueMessageEntity]> {
        let messages = await IntentData.dueMessages()
        return .result(value: messages)
    }
}

struct MarkMessageSentIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark BlueNudge Message Sent"
    static let description = IntentDescription(
        "Records a due message as sent so it leaves the queue and shows in Activity on every device."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Message")
    var message: DueMessageEntity

    func perform() async throws -> some IntentResult {
        _ = await IntentData.markSent(key: message.id)
        return .result()
    }
}

struct OpenSendQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Open BlueNudge Send Queue"
    static let description = IntentDescription("Opens BlueNudge on the list of messages ready to send.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.presentSendQueue()
        return .result()
    }
}

struct BlueNudgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSendQueueIntent(),
            phrases: [
                "Show messages ready in \(.applicationName)",
                "Open \(.applicationName) send queue",
            ],
            shortTitle: "Ready to Send",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: GetDueMessagesIntent(),
            phrases: ["Get due messages from \(.applicationName)"],
            shortTitle: "Due Messages",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
    }
}

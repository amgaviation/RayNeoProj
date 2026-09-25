import AppIntents
import Foundation
import ReminderCore

/// "Hey Siri, text me a reminder with BlueNudge": a one-time reminder from Siri,
/// Shortcuts or Spotlight, without opening the app.
struct TextMeReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Text Me a Reminder"
    static let description = IntentDescription(
        "Schedules a one-time reminder. BlueNudge texts it to you through the Mac relay, or sends a notification when no number is set."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Reminder", requestValueDialog: "What should I remind you about?")
    var message: String

    @Parameter(title: "Time", requestValueDialog: "When should I remind you?")
    var date: Date

    static var parameterSummary: some ParameterSummary {
        Summary("Remind me \(\.$message) at \(\.$date)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .result(dialog: "There was nothing to remind you about.")
        }
        guard date > Date() else {
            return .result(dialog: "That time has already passed. Try a later time.")
        }
        let repository = Repository(context: DataStore.shared.mainContext)
        let reminder = repository.addOneTimeReminder(
            title: String(text.prefix(40)),
            message: text,
            at: date
        )
        AppState.shared.dataDidChange()
        let when = WhenPhrase.describe(reminder.schedule.start)
        switch reminder.method {
        case .relay:
            return .result(dialog: "Okay, I'll text you \(when).")
        case .notification:
            return .result(dialog: "Okay, I'll remind you \(when).")
        }
    }
}

struct BlueNudgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TextMeReminderIntent(),
            phrases: [
                "Text me a reminder with \(.applicationName)",
                "Remind me with \(.applicationName)",
                "Add a \(.applicationName) reminder",
            ],
            shortTitle: "Text Me a Reminder",
            systemImageName: "message.badge"
        )
    }
}

import SwiftUI
import UIKit
import SwiftData
import UserNotifications
import ReminderCore

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var appState = AppState.shared
    @Query(sort: \SharedSettings.createdAt) private var settingsRecords: [SharedSettings]
    @Query(sort: \RelayHeartbeat.lastSeen, order: .reverse) private var heartbeats: [RelayHeartbeat]

    var body: some View {
        NavigationStack {
            Group {
                if let settings = settingsRecords.first {
                    SettingsForm(settings: settings, heartbeats: heartbeats)
                } else {
                    ProgressView()
                        .onAppear { Repository(context: modelContext).settings() }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct SettingsForm: View {
    @Bindable var settings: SharedSettings
    let heartbeats: [RelayHeartbeat]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @ObservedObject private var appState = AppState.shared

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isConfirmingLogDeletion = false

    var body: some View {
        Form {
            Section {
                TextField("Your name or business", text: $settings.senderName)
                HStack {
                    Text("Default country code")
                    Spacer()
                    Text("+")
                        .foregroundStyle(.secondary)
                    TextField("1", text: $settings.defaultCountryCode)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
                Picker("New reminders", selection: Binding(
                    get: { settings.defaultMethod },
                    set: { settings.defaultMethod = $0 }
                )) {
                    ForEach(DeliveryMethod.allCases) { method in
                        Text(method.shortTitle).tag(method)
                    }
                }
            } header: {
                Text("Messages")
            } footer: {
                Text("Your name fills {sender} in messages. The country code is used for numbers typed without one.")
            }

            Section {
                Toggle("Add opt-out line", isOn: $settings.appendOptOutFooter)
                if settings.appendOptOutFooter {
                    TextField("Opt-out line", text: $settings.optOutFooterText)
                }
                Toggle("Honor STOP replies", isOn: $settings.honorOptOutReplies)
                if settings.honorOptOutReplies {
                    Toggle("Confirm opt-outs", isOn: $settings.sendOptOutConfirmation)
                    if settings.sendOptOutConfirmation {
                        TextField("Confirmation", text: $settings.optOutConfirmationText, axis: .vertical)
                            .lineLimit(2...4)
                    }
                }
            } header: {
                Text("Opt-outs")
            } footer: {
                Text("The Mac relay watches replies and marks anyone who texts STOP, UNSUBSCRIBE, CANCEL and similar as opted out, then sends the confirmation once. Replying START opts them back in. Needs Full Disk Access on the Mac.")
            }

            Section {
                if heartbeats.isEmpty {
                    RelayStatusView(heartbeat: nil)
                } else {
                    ForEach(heartbeats) { heartbeat in
                        RelayStatusView(heartbeat: heartbeat)
                    }
                }
                NavigationLink("Set up the Mac relay") { RelaySetupGuideView() }
                Stepper(value: $settings.graceMinutes, in: 5...1_440, step: 5) {
                    LabeledContent("Send late messages for", value: Self.minutesText(settings.graceMinutes))
                }
                Stepper(value: $settings.hourlySendCap, in: 5...500, step: 5) {
                    LabeledContent("Max per hour", value: "\(settings.hourlySendCap)")
                }
                Stepper(value: $settings.secondsBetweenSends, in: 1...60) {
                    LabeledContent("Gap between messages", value: "\(settings.secondsBetweenSends) s")
                }
                Toggle("Fall back to SMS", isOn: $settings.smsFallback)
            } header: {
                Text("Mac relay")
            } footer: {
                Text("If the Mac was asleep or offline, reminders later than the window above are logged as missed instead of arriving late. The hourly cap and gap keep sending patterns normal so Apple doesn't flag the account. SMS fallback retries failed iMessages as texts through your iPhone (Text Message Forwarding).")
            }

            Section {
                LabeledContent("Notifications", value: Self.describe(notificationStatus))
                if notificationStatus == .notDetermined {
                    Button("Allow notifications") {
                        Task {
                            await NotificationScheduler.requestAuthorization()
                            await refreshNotificationStatus()
                            appState.dataDidChange()
                        }
                    }
                } else if notificationStatus == .denied {
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                NavigationLink("Send automatically with Shortcuts") { ShortcutsGuideView() }
            } header: {
                Text("Tap to send")
            } footer: {
                Text("Tap-to-send reminders alert you at the scheduled time with the message ready to go.")
            }

            Section {
                LabeledContent("Sync", value: DataStore.shared.syncSummary)
                if DataStore.shared.isSyncConfigured {
                    SyncStatusLine()
                }
                LabeledContent("iCloud account", value: appState.iCloudAccount)
                Stepper(value: $settings.logRetentionDays, in: 7...730, step: 7) {
                    LabeledContent("Keep activity for", value: "\(settings.logRetentionDays) days")
                }
                Button("Clear activity log", role: .destructive) { isConfirmingLogDeletion = true }
            } header: {
                Text("Data")
            } footer: {
                Text(DataStore.shared.syncDetail)
            }

            Section("About") {
                LabeledContent("Version", value: DeviceInfo.appVersion)
                NavigationLink("Costs and limits") { CostsView() }
            }
        }
        .task { await refreshNotificationStatus() }
        .onChange(of: settings.defaultCountryCode) { _, newValue in
            let digits = newValue.filter(\.isNumber)
            if digits != newValue { settings.defaultCountryCode = digits }
        }
        .onDisappear(perform: save)
        .confirmationDialog("Clear the whole activity log?", isPresented: $isConfirmingLogDeletion, titleVisibility: .visible) {
            Button("Clear log", role: .destructive, action: clearLog)
        } message: {
            Text("This removes delivery history on every device. Reminders due in the next day could be sent again if their records are gone, so only do this when nothing is due.")
        }
    }

    private func save() {
        settings.updatedAt = Date()
        Repository(context: modelContext).save()
        appState.dataDidChange()
    }

    private func clearLog() {
        do {
            try modelContext.delete(model: DeliveryRecord.self)
            try modelContext.save()
        } catch {
            NSLog("BlueNudge: clearing the log failed: \(error)")
        }
        appState.dataDidChange()
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await NotificationScheduler.authorizationStatus()
    }

    static func minutesText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return hours == hours.rounded() ? "\(Int(hours)) h" : String(format: "%.1f h", hours)
    }

    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "On"
        case .provisional: return "Delivered quietly"
        case .ephemeral: return "Temporary"
        case .denied: return "Off"
        case .notDetermined: return "Not set up"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Guides

struct RelaySetupGuideView: View {
    var body: some View {
        List {
            Section {
                Text("The relay is the only way to send iMessages fully unattended: Apple doesn't let iPhone apps send messages on their own. Any Mac on macOS 14 or later that stays on works, and it costs nothing per message.")
            }
            Section("On the Mac") {
                GuideStep(number: 1, text: "Open Messages and sign in with the Apple Account (or iPhone number) the reminders should come from.")
                GuideStep(number: 2, text: "Sign in to iCloud with the same Apple Account this iPhone uses, so the relay sees your reminders.")
                GuideStep(number: 3, text: "Build and run the BlueNudgeRelay target from the Xcode project. It lives in the menu bar.")
                GuideStep(number: 4, text: "Click Grant access when the relay asks to control Messages.")
                GuideStep(number: 5, text: "Optional: give BlueNudge Relay Full Disk Access (System Settings › Privacy & Security) so it can confirm delivery and handle STOP replies.")
                GuideStep(number: 6, text: "Turn on Open at login and Keep this Mac awake in the relay window.")
            }
            Section("For SMS fallback") {
                GuideStep(number: 1, text: "On this iPhone: Settings › Apps › Messages › Text Message Forwarding, and allow the Mac.")
                GuideStep(number: 2, text: "Turn on Fall back to SMS in Settings here.")
            }
            Section("Good to know") {
                Text("Keep volumes reasonable and only message people who agreed to it. Apple can restrict accounts that send lots of unsolicited messages.")
                Text("Automatic reminders show up as Late on the Today screen when the relay misses them, with a button to send them from the iPhone instead.")
            }
        }
        .navigationTitle("Mac relay")
    }
}

struct ShortcutsGuideView: View {
    var body: some View {
        List {
            Section {
                Text("Shortcuts can send tap-to-send messages without you touching the phone, at fixed times of day. iOS sometimes skips automations while the iPhone is locked, so treat this as best-effort; the Mac relay is the reliable option.")
            }
            Section("Build the shortcut") {
                GuideStep(number: 1, text: "Open Shortcuts › Automation › New Automation › Time of Day, pick a time (e.g. 9:00 AM daily) and choose Run Immediately.")
                GuideStep(number: 2, text: "Add the action Get Due BlueNudge Messages.")
                GuideStep(number: 3, text: "Add Repeat with Each, using the messages from step 2.")
                GuideStep(number: 4, text: "Inside the loop add Send Message: set Message to Repeat Item › Text and Recipients to Repeat Item › Handle. Turn off Show When Run.")
                GuideStep(number: 5, text: "Still inside the loop add Mark BlueNudge Message Sent with Repeat Item.")
                GuideStep(number: 6, text: "Repeat the automation for any other times you need.")
            }
            Section {
                Text("Messages sent this way are logged as sent via Shortcuts on every device.")
            }
        }
        .navigationTitle("Shortcuts")
    }
}

struct CostsView: View {
    var body: some View {
        List {
            Section("What it costs") {
                LabeledContent("Per message", value: "$0")
                LabeledContent("Servers", value: "None")
                LabeledContent("Sync", value: "Your iCloud")
                Text("Messages go out through the Messages app from your own Apple Account or number, so there are no per-text fees like SMS gateways charge. Sync uses your private iCloud database, which Apple provides free with a developer account.")
            }
            Section("Limits") {
                Text("iPhone apps cannot send messages by themselves; Apple requires a tap. That is why unattended sending needs the Mac relay.")
                Text("Recipients without iMessage (Android) need SMS fallback through your iPhone, which uses your carrier plan.")
                Text("iOS keeps at most 64 scheduled notifications per app, so tap-to-send alerts are scheduled for the next 60 occurrences and refreshed whenever the app opens.")
            }
        }
        .navigationTitle("Costs and limits")
    }
}

struct GuideStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

/// Last iCloud sync, or the reason it failed.
private struct SyncStatusLine: View {
    @ObservedObject private var monitor = SyncMonitor.shared

    var body: some View {
        LabeledContent("iCloud") {
            Text(monitor.summary)
                .foregroundStyle(monitor.lastError == nil ? Color.secondary : Color.red)
                .multilineTextAlignment(.trailing)
        }
    }
}

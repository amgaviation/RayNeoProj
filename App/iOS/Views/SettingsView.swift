import SwiftUI
import UIKit
import SwiftData
import UserNotifications
import ReminderCore

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SharedSettings.createdAt) private var settingsRecords: [SharedSettings]
    @Query(sort: \Recipient.createdAt) private var recipients: [Recipient]
    @Query(sort: \RelayHeartbeat.lastSeen, order: .reverse) private var heartbeats: [RelayHeartbeat]

    var body: some View {
        NavigationStack {
            Group {
                if let settings = settingsRecords.first {
                    SettingsForm(settings: settings, me: recipients.first, heartbeats: heartbeats)
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
    let me: Recipient?
    let heartbeats: [RelayHeartbeat]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @ObservedObject private var appState = AppState.shared

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isConfirmingLogDeletion = false
    @State private var isEditingNumber = false

    var body: some View {
        Form {
            Section {
                Button {
                    isEditingNumber = true
                } label: {
                    LabeledContent("Texts go to") {
                        Text(me?.displayHandle ?? "Not set")
                            .foregroundStyle(me == nil ? Color.orange : Color.secondary)
                    }
                }
                .foregroundStyle(Color.primary)
                if let me {
                    Toggle("Pause all texts", isOn: Binding(
                        get: { me.optedOut },
                        set: { paused in
                            me.setOptedOut(paused, source: "manual")
                            save()
                        }
                    ))
                }
                Picker("New reminders", selection: Binding(
                    get: { settings.defaultMethod },
                    set: { settings.defaultMethod = $0 }
                )) {
                    ForEach(DeliveryMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
            } header: {
                Text("Your texts")
            } footer: {
                if me?.optedOut == true {
                    Text("Texts are paused: reminders due now are logged as paused, not sent. Notification reminders still arrive.")
                } else {
                    Text("Use a number or email this iPhone receives iMessages on.")
                }
            }

            Section {
                Toggle("Snooze by replying", isOn: $settings.honorSnoozeReplies)
                Toggle("STOP pauses, START resumes", isOn: $settings.honorOptOutReplies)
                Toggle("Confirm replies", isOn: $settings.confirmReplies)
                Toggle("Add a line to each text", isOn: $settings.appendOptOutFooter)
                if settings.appendOptOutFooter {
                    TextField("Line to add", text: $settings.optOutFooterText)
                }
            } header: {
                Text("Replies")
            } footer: {
                Text("Reply SNOOZE for another text in 10 minutes, or SNOOZE 30, 2H, LATER. STOP pauses every text until you reply START. Needs Full Disk Access for BlueNudge Relay on the Mac.")
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
                    LabeledContent("Send late texts for", value: Self.minutesText(settings.graceMinutes))
                }
                Stepper(value: $settings.hourlySendCap, in: 5...120, step: 5) {
                    LabeledContent("Max texts per hour", value: "\(settings.hourlySendCap)")
                }
            } header: {
                Text("Mac relay")
            } footer: {
                Text("If the Mac was asleep or offline, texts later than this are logged as missed instead of arriving late.")
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
            } header: {
                Text("Notification reminders")
            } footer: {
                Text("\"Notification only\" reminders work without a Mac. Long-press one to snooze it for 10 minutes.")
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
                Button("Clear activity", role: .destructive) { isConfirmingLogDeletion = true }
            } header: {
                Text("Data")
            } footer: {
                Text(DataStore.shared.syncDetail)
            }

            Section("About") {
                LabeledContent("Version", value: DeviceInfo.appVersion)
                NavigationLink("How it works and what it costs") { CostsView() }
            }
        }
        .task { await refreshNotificationStatus() }
        .onDisappear(perform: save)
        .sheet(isPresented: $isEditingNumber) {
            NavigationStack { MyNumberView() }
        }
        .confirmationDialog("Clear all activity?", isPresented: $isConfirmingLogDeletion, titleVisibility: .visible) {
            Button("Clear activity", role: .destructive, action: clearLog)
        } message: {
            Text("This removes the history on every device. Reminders due in the next day could be texted again if their records are gone, so only do this when nothing is due.")
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
                Text("iPhone apps can't send texts on their own. BlueNudge Relay runs on a Mac and texts your reminders to you through Messages. Any Mac on macOS 14 or later that stays on works, and there's no charge per text.")
            }
            Section {
                GuideStep(number: 1, text: "Create a second Apple Account for the Mac to text from (free at account.apple.com). If the Mac texted from your own account, the texts would look like you sent them and your iPhone wouldn't alert you.")
                GuideStep(number: 2, text: "On the Mac, open Messages › Settings › iMessage and sign in with that second account. Keep the Mac's iCloud (System Settings) on your own account so it sees your reminders.")
                GuideStep(number: 3, text: "Build and run BlueNudgeRelay from the Xcode project. It lives in the menu bar.")
                GuideStep(number: 4, text: "Click Grant access when it asks to control Messages.")
                GuideStep(number: 5, text: "Give BlueNudge Relay Full Disk Access (System Settings › Privacy & Security) so it can read replies like SNOOZE and STOP and confirm delivery.")
                GuideStep(number: 6, text: "Turn on Open at login and Keep this Mac awake in the relay window.")
            } header: {
                Text("On the Mac")
            }
            Section {
                GuideStep(number: 1, text: "Save the second account's email as a contact named BlueNudge, so its texts don't land in Unknown Senders without an alert.")
                GuideStep(number: 2, text: "Enter your number in BlueNudge › Settings › Texts go to.")
                GuideStep(number: 3, text: "Use Send Test in the relay window to check a text arrives.")
            } header: {
                Text("On this iPhone")
            }
            Section("Good to know") {
                Text("When the Mac is off or asleep, texts wait. Late ones show on the Today screen, and anything later than the window in Settings is logged as missed.")
                Text("Apple can restrict accounts that send large numbers of automated messages. Reminders to yourself are low volume; keep hourly ones to waking hours.")
            }
        }
        .navigationTitle("Mac relay")
    }
}

struct CostsView: View {
    var body: some View {
        List {
            Section("What it costs") {
                LabeledContent("Per text", value: "$0")
                LabeledContent("Servers", value: "None")
                LabeledContent("Sync", value: "Your iCloud")
                Text("Texts go out through Messages on your Mac, so there are no per-text fees like SMS services charge. Reminders sync through your private iCloud database.")
            }
            Section("How it works") {
                Text("Your reminders live in your iCloud. BlueNudge Relay on the Mac sees them, and at the right time asks Messages to text you. Your iPhone gets it like any other text.")
                Text("Replies go back to the Mac. The relay reads them to snooze or pause, which needs Full Disk Access.")
            }
            Section("Limits") {
                Text("iPhone apps can't send texts by themselves; Apple requires a tap. That's why texts need the Mac.")
                Text("Without a Mac, choose Notification only. iOS keeps up to 64 scheduled notifications per app, so the next 60 are scheduled and refreshed whenever the app opens.")
            }
        }
        .navigationTitle("How it works")
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

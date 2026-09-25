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
    @ObservedObject private var texting = TextingAccount.shared
    @ObservedObject private var store = SubscriptionStore.shared

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var alarmAccess = AlarmScheduler.access
    @State private var isConfirmingLogDeletion = false

    var body: some View {
        Form {
            Section {
                if texting.isConfigured {
                    NavigationLink {
                        TextingAccountView()
                    } label: {
                        LabeledContent {
                            Text(textingSummary)
                                .foregroundStyle(texting.isReady ? Color.secondary : Color.orange)
                        } label: {
                            Label("Texts", systemImage: DeliveryMethod.sms.symbolName)
                        }
                    }
                }
                Picker("New reminders", selection: Binding(
                    get: { settings.defaultMethod },
                    set: { settings.defaultMethod = $0 }
                )) {
                    ForEach(DeliveryMethod.available(hasRelay: !heartbeats.isEmpty, including: settings.defaultMethod)) { method in
                        Text(method.title).tag(method)
                    }
                }
            } header: {
                Text("Delivery")
            } footer: {
                Text("Each reminder can use its own method. Change it in the reminder.")
            }

            if AlarmScheduler.isSupported {
                Section {
                    LabeledContent("Alarms", value: Self.describe(alarmAccess))
                    if alarmAccess == .notDetermined {
                        Button("Allow alarms") {
                            Task {
                                await AlarmScheduler.requestAccess()
                                alarmAccess = AlarmScheduler.access
                                appState.dataDidChange()
                            }
                        }
                    } else if alarmAccess == .denied {
                        Button("Open iPhone Settings", action: openSettings)
                    }
                } header: {
                    Text("Alarm reminders")
                } footer: {
                    Text("Alarms ring like the Clock app's, even on silent or in a Focus, until you stop them. Free.")
                }
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
                    Button("Open iPhone Settings", action: openSettings)
                }
            } header: {
                Text("Notification reminders")
            } footer: {
                Text("Free. Long-press one to snooze it for 10 minutes.")
            }

            Section {
                NavigationLink {
                    MacRelaySettingsView(settings: settings, me: me, heartbeats: heartbeats)
                } label: {
                    LabeledContent {
                        Text(relaySummary)
                    } label: {
                        Label("Text from my Mac", systemImage: DeliveryMethod.relay.symbolName)
                    }
                }
            } footer: {
                Text("Free iMessages sent by BlueNudge Relay on a Mac you own that stays on.")
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
                if let url = store.privacyPolicyURL {
                    Link("Privacy policy", destination: url)
                }
                if let url = store.termsURL {
                    Link("Terms of use", destination: url)
                }
            }
        }
        .task {
            await refreshNotificationStatus()
            alarmAccess = AlarmScheduler.access
        }
        .onDisappear(perform: save)
        .confirmationDialog("Clear all activity?", isPresented: $isConfirmingLogDeletion, titleVisibility: .visible) {
            Button("Clear activity", role: .destructive, action: clearLog)
        } message: {
            Text("This removes the history on every device. Reminders due in the next day could be texted again by a Mac relay if their records are gone, so only do this when nothing is due.")
        }
    }

    private var textingSummary: String {
        if !texting.isSignedIn { return "Sign in" }
        guard let status = texting.status else { return HandleNormalizer.displayFormat(texting.session?.phone ?? "") }
        if !status.subscribed { return "Not subscribed" }
        if status.textsPaused { return "Paused" }
        return HandleNormalizer.displayFormat(status.phone)
    }

    private var relaySummary: String {
        guard let heartbeat = heartbeats.first else { return "Not set up" }
        return heartbeat.isOnline() ? "Online" : "Offline"
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
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

    static func describe(_ access: AlarmScheduler.Access) -> String {
        switch access {
        case .authorized: return "On"
        case .denied: return "Off"
        case .notDetermined: return "Not set up"
        case .unsupported: return "Needs iOS 26"
        }
    }
}

/// "Text from my Mac": where the relay texts, replies, and the relay's status.
struct MacRelaySettingsView: View {
    @Bindable var settings: SharedSettings
    let me: Recipient?
    let heartbeats: [RelayHeartbeat]

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var appState = AppState.shared
    @State private var isEditingNumber = false

    var body: some View {
        Form {
            Section {
                if heartbeats.isEmpty {
                    RelayStatusView(heartbeat: nil)
                } else {
                    ForEach(heartbeats) { heartbeat in
                        RelayStatusView(heartbeat: heartbeat)
                    }
                }
                NavigationLink("Set up the Mac relay") { RelaySetupGuideView() }
            } footer: {
                Text("BlueNudge Relay runs on a Mac that stays on and texts your \"Text from my Mac\" reminders through Messages, at no cost per text.")
            }

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
                    Toggle("Pause Mac texts", isOn: Binding(
                        get: { me.optedOut },
                        set: { paused in
                            me.setOptedOut(paused, source: "manual")
                            save()
                        }
                    ))
                }
            } header: {
                Text("Your number")
            } footer: {
                if me?.optedOut == true {
                    Text("Mac texts are paused: reminders due now are logged as paused, not sent.")
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
                Text("Reply SNOOZE for another text in 10 minutes, or SNOOZE 30, 2H, LATER. STOP pauses every Mac text until you reply START. Needs Full Disk Access for BlueNudge Relay on the Mac.")
            }

            Section {
                Stepper(value: $settings.graceMinutes, in: 5...1_440, step: 5) {
                    LabeledContent("Send late texts for", value: SettingsForm.minutesText(settings.graceMinutes))
                }
                Stepper(value: $settings.hourlySendCap, in: 5...120, step: 5) {
                    LabeledContent("Max texts per hour", value: "\(settings.hourlySendCap)")
                }
            } header: {
                Text("Relay")
            } footer: {
                Text("If the Mac was asleep or offline, texts later than this are logged as missed instead of arriving late.")
            }
        }
        .navigationTitle("Text from my Mac")
        .onDisappear(perform: save)
        .sheet(isPresented: $isEditingNumber) {
            NavigationStack { MyNumberView() }
        }
    }

    private func save() {
        settings.updatedAt = Date()
        Repository(context: modelContext).save()
        appState.dataDidChange()
    }
}

// MARK: - Guides

struct RelaySetupGuideView: View {
    var body: some View {
        List {
            Section {
                Text("BlueNudge Relay runs on a Mac and texts your \"Text from my Mac\" reminders to you through Messages. Any Mac on macOS 14 or later that stays on works, and there's no charge per text.")
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
                GuideStep(number: 2, text: "Enter your number in BlueNudge › Settings › Text from my Mac.")
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
            Section {
                MethodCostRow(method: .sms, cost: "Subscription", detail: "Sent by BlueNudge's texting service to your phone number. Works on any iPhone, no Mac needed. Reply SNOOZE or STOP.")
                MethodCostRow(method: .alarm, cost: "Free", detail: "Scheduled on this iPhone with iOS 26's alarms. Rings through silent mode and Focus until you stop it.")
                MethodCostRow(method: .notification, cost: "Free", detail: "A regular notification on this iPhone. Easy to swipe away, so best for things that can wait.")
                MethodCostRow(method: .relay, cost: "Free", detail: "An iMessage sent by BlueNudge Relay on a Mac you own. The Mac has to stay on.")
            } header: {
                Text("Ways to get a reminder")
            }
            Section("Your data") {
                Text("Reminders live on this iPhone and in your private iCloud. Only reminders set to \"Text me\" are sent to BlueNudge's server: the text and when to send it, for the next few weeks, plus your phone number.")
                Text("Deleting your texting account removes your number, queued texts and text history from the server.")
            }
            Section("Limits") {
                Text("iPhone apps can't send texts on their own; Apple requires a tap. That's why texts come from BlueNudge's server or your Mac.")
                Text("iOS keeps a limited number of scheduled notifications and alarms per app, so the next ones are set ahead and topped up whenever BlueNudge opens or refreshes in the background.")
            }
        }
        .navigationTitle("How it works")
    }
}

private struct MethodCostRow: View {
    let method: DeliveryMethod
    let cost: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: method.symbolName)
                .font(.title3)
                .foregroundStyle(method.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(method.title).font(.headline)
                    Spacer()
                    Text(cost)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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

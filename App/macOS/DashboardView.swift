import AppKit
import SwiftData
import SwiftUI
import ReminderCore

/// Setup checklist, activity and a test sender, in one window.
struct DashboardView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case setup = "Setup"
        case activity = "Activity"
        case test = "Test"
        case settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .setup: return "checklist"
            case .activity: return "list.bullet.rectangle"
            case .test: return "paperplane"
            case .settings: return "gearshape"
            }
        }
    }

    @State private var pane: Pane?

    init(initialPane: Pane = .setup) {
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch pane ?? .setup {
            case .setup: SetupView()
            case .activity: RelayActivityView()
            case .test: TestSendView()
            case .settings: RelaySettingsView()
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

// MARK: - Setup

private struct SetupView: View {
    @ObservedObject private var engine = RelayEngine.shared
    @ObservedObject private var prefs = RelayPreferences.shared
    @ObservedObject private var sync = SyncMonitor.shared

    @State private var loginItemEnabled = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: engine.condition.symbolName)
                        .font(.largeTitle)
                        .foregroundStyle(engine.condition.needsAttention ? Color.red : Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(engine.condition.title).font(.title2.bold())
                        Text(engine.note ?? engine.condition.detail)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Messages") {
                ChecklistRow(
                    title: "Messages uses a second Apple Account",
                    detail: "In Messages › Settings › iMessage, sign in with an Apple Account that isn't the one on your iPhone. Texts from your own account show up as sent by you, so your iPhone won't alert you. Leave this Mac's iCloud (System Settings) on your own account.",
                    state: .info
                ) {
                    Button("Open Messages") { MessagesSender.openMessages() }
                }
                ChecklistRow(
                    title: "Allowed to control Messages",
                    detail: engine.automation == .granted
                        ? "The relay can send through Messages."
                        : "Needed to send. macOS asks once; if you denied it, turn it on in Privacy & Security › Automation.",
                    state: engine.automation == .granted ? .done : .todo
                ) {
                    if engine.automation == .denied {
                        Button("Open Automation settings") { SystemSettingsLink.open(SystemSettingsLink.automation) }
                    } else if engine.automation != .granted {
                        Button("Grant access") { Task { await engine.requestAutomationAccess() } }
                    }
                }
                ChecklistRow(
                    title: "Full Disk Access (recommended)",
                    detail: engine.hasFullDiskAccess
                        ? "Replies (SNOOZE, STOP, START) and delivery confirmations are on."
                        : "Lets the relay read your replies (SNOOZE, STOP, START) and confirm delivery. Add BlueNudge Relay under Full Disk Access, then click Recheck.",
                    state: engine.hasFullDiskAccess ? .done : .optional
                ) {
                    if !engine.hasFullDiskAccess {
                        Button("Open settings") { SystemSettingsLink.open(SystemSettingsLink.fullDiskAccess) }
                        Button("Recheck") { Task { await engine.refreshPermissions(ask: false) } }
                    }
                }
            }

            Section("iCloud") {
                ChecklistRow(
                    title: "Syncing with your iPhone",
                    detail: syncDetail,
                    state: DataStore.shared.isSyncConfigured && engine.iCloudAccount == "Signed in" && sync.lastError == nil ? .done : .todo
                ) {
                    EmptyView()
                }
                LabeledContent("Texts go to", value: engine.textsGoTo ?? "Not set yet. Add it in the iPhone app › Settings.")
                LabeledContent("Text reminders", value: "\(engine.automaticRemindersSeen)")
            }

            Section("Keep it running") {
                Toggle(isOn: Binding(
                    get: { loginItemEnabled },
                    set: { newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                            loginItemError = nil
                        } catch {
                            loginItemError = error.localizedDescription
                        }
                        loginItemEnabled = LoginItem.isEnabled
                    }
                )) {
                    VStack(alignment: .leading) {
                        Text("Open at login")
                        if LoginItem.needsApproval {
                            Text("Approve it in System Settings › General › Login Items.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let loginItemError {
                            Text(loginItemError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Toggle(isOn: $prefs.keepAwake) {
                    VStack(alignment: .leading) {
                        Text("Keep this Mac awake")
                        Text("Stops idle sleep so reminders go out on time. The display can still sleep; a closed laptop lid still sleeps the Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(
                    get: { !prefs.isPaused },
                    set: { engine.setPaused(!$0) }
                )) {
                    Text("Send texts")
                }
            }

            Section {
                HStack {
                    Button("Done with setup") {
                        prefs.hasCompletedSetup = true
                        NSApplication.shared.keyWindow?.close()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.automation != .granted)
                    Spacer()
                    Button("Check now") { Task { await engine.tick(forceHeartbeat: true) } }
                        .disabled(engine.isChecking)
                }
            } footer: {
                Text("The relay keeps running from the menu bar after you close this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .task { await engine.refreshPermissions(ask: false) }
    }

    private var syncDetail: String {
        guard DataStore.shared.isSyncConfigured else {
            return DataStore.shared.syncDetail
        }
        return "\(sync.summary). iCloud account: \(engine.iCloudAccount). Sign in to iCloud on this Mac with the same Apple Account as the iPhone; new reminders usually arrive within a minute."
    }
}

private enum ChecklistStatus {
    case done, todo, optional, info
}

private struct ChecklistRow<Actions: View>: View {
    let title: String
    let detail: String
    let state: ChecklistStatus
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { actions() }
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .todo: return "exclamationmark.circle.fill"
        case .optional: return "circle.dashed"
        case .info: return "info.circle"
        }
    }

    private var color: Color {
        switch state {
        case .done: return .green
        case .todo: return .orange
        case .optional: return .secondary
        case .info: return .blue
        }
    }
}

// MARK: - Activity

private struct RelayActivityView: View {
    @ObservedObject private var engine = RelayEngine.shared
    @Query private var records: [DeliveryRecord]

    init() {
        var descriptor = FetchDescriptor<DeliveryRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 300
        _records = Query(descriptor)
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(records) {
                TableColumn("When") { record in
                    Text((record.sentAt ?? record.createdAt).formatted(date: .abbreviated, time: .shortened))
                }
                .width(min: 120, ideal: 140)
                TableColumn("Reminder") { record in
                    Text(record.reminderTitle)
                }
                .width(min: 100, ideal: 150)
                TableColumn("Text") { record in
                    Text(record.messageText)
                        .foregroundStyle(.secondary)
                        .help(record.messageText)
                }
                TableColumn("Status") { record in
                    Text(record.status.title)
                        .foregroundStyle(color(for: record.status))
                }
                .width(min: 70, ideal: 90)
                TableColumn("Via") { record in
                    Text([record.channel.title, record.serviceUsed].filter { !$0.isEmpty }.joined(separator: " · "))
                }
                .width(min: 80, ideal: 120)
                TableColumn("Note") { record in
                    Text(record.errorMessage)
                        .foregroundStyle(.secondary)
                        .help(record.errorMessage)
                }
            }

            if !engine.events.isEmpty {
                Divider()
                List(engine.events.prefix(30)) { event in
                    HStack(alignment: .firstTextBaseline) {
                        Text(event.date.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(event.text)
                            .font(.caption)
                            .foregroundStyle(event.isProblem ? Color.red : Color.primary)
                    }
                }
                .frame(height: 150)
            }
        }
        .navigationTitle("Activity")
    }

    private func color(for status: DeliveryStatus) -> Color {
        switch status {
        case .delivered: return .green
        case .sent: return .blue
        case .failed: return .red
        case .missed: return .orange
        case .optedOut: return .purple
        case .sending, .skipped: return .secondary
        }
    }
}

// MARK: - Test

private struct TestSendView: View {
    @ObservedObject private var engine = RelayEngine.shared

    @State private var handle = ""
    @State private var text = "BlueNudge test ✅ If your iPhone buzzed, you're all set."
    @State private var result: String?
    @State private var isSending = false

    var body: some View {
        Form {
            Section {
                TextField("Your phone number or iMessage email", text: $handle)
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(2...5)
            } footer: {
                Text("Sends one text right now. It should arrive on your iPhone as a new message from the relay's Apple Account, with an alert. It isn't added to Activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Send test text") {
                        isSending = true
                        Task {
                            result = await engine.sendTest(to: handle, text: text, service: .iMessage)
                            isSending = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(handle.isEmpty || text.isEmpty || isSending)
                    if isSending { ProgressView().controlSize(.small) }
                }
                if let result {
                    Text(result)
                        .foregroundStyle(result.hasPrefix("Sent") ? Color.green : Color.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Test")
        .onAppear {
            if handle.isEmpty, let textsGoTo = engine.textsGoTo {
                handle = textsGoTo
            }
        }
    }
}

// MARK: - Shared settings

private struct RelaySettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SharedSettings.createdAt) private var settingsRecords: [SharedSettings]
    @ObservedObject private var engine = RelayEngine.shared

    var body: some View {
        Group {
            if let settings = settingsRecords.first {
                RelaySettingsForm(settings: settings)
            } else {
                ProgressView()
                    .onAppear { Repository(context: modelContext).settings() }
            }
        }
        .navigationTitle("Settings")
    }
}

private struct RelaySettingsForm: View {
    @Bindable var settings: SharedSettings
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var engine = RelayEngine.shared

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.graceMinutes, in: 5...1_440, step: 5) {
                    LabeledContent("Send late texts for up to", value: "\(settings.graceMinutes) min")
                }
                Stepper(value: $settings.hourlySendCap, in: 5...120, step: 5) {
                    LabeledContent("Max texts per hour", value: "\(settings.hourlySendCap)")
                }
                Stepper(value: $settings.secondsBetweenSends, in: 1...60) {
                    LabeledContent("Gap between texts", value: "\(settings.secondsBetweenSends) s")
                }
            } header: {
                Text("Sending")
            } footer: {
                Text("These sync with the iPhone app.")
            }

            Section {
                Toggle("Snooze by replying", isOn: $settings.honorSnoozeReplies)
                Toggle("STOP pauses, START resumes", isOn: $settings.honorOptOutReplies)
                Toggle("Confirm replies", isOn: $settings.confirmReplies)
                TextField("Reply to STOP", text: $settings.optOutConfirmationText, axis: .vertical)
                    .lineLimit(2...4)
                    .disabled(!settings.honorOptOutReplies || !settings.confirmReplies)
            } header: {
                Text("Replies")
            } footer: {
                Text("Replies are read from the Messages database, which needs Full Disk Access.")
            }

            Section("Other relays") {
                Text("If you replaced a Mac, forget the old one so the iPhone stops showing it as offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Forget other relay Macs") { engine.forgetOtherRelays() }
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            settings.updatedAt = Date()
            Repository(context: modelContext).save()
        }
    }
}

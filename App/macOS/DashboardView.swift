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
                    title: "Messages is signed in",
                    detail: "Open Messages and sign in with the Apple Account or iPhone number reminders should come from.",
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
                    title: "Full Disk Access (optional)",
                    detail: engine.hasFullDiskAccess
                        ? "Delivery confirmations, SMS fallback on failure and STOP replies are on."
                        : "Lets the relay read the Messages database to confirm delivery and honor STOP replies. Add BlueNudge Relay under Full Disk Access, then click Recheck.",
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
                LabeledContent("Automatic reminders seen", value: "\(engine.automaticRemindersSeen)")
                LabeledContent("People seen", value: "\(engine.peopleSeen)")
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
                    Text("Send automatic reminders")
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
                TableColumn("To") { record in
                    Text(record.displayRecipient)
                }
                .width(min: 100, ideal: 140)
                TableColumn("Reminder") { record in
                    Text(record.reminderTitle)
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
    @State private var text = "Test from BlueNudge Relay ✅"
    @State private var useSMS = false
    @State private var result: String?
    @State private var isSending = false

    var body: some View {
        Form {
            Section {
                TextField("Phone number or iMessage email", text: $handle)
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(2...5)
                Picker("Service", selection: $useSMS) {
                    Text("iMessage").tag(false)
                    Text("SMS (via iPhone)").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Sends one message right now to check Messages access. It is not added to the reminder log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Send test message") {
                        isSending = true
                        Task {
                            result = await engine.sendTest(to: handle, text: text, service: useSMS ? .sms : .iMessage)
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
                    LabeledContent("Send late reminders for up to", value: "\(settings.graceMinutes) min")
                }
                Stepper(value: $settings.hourlySendCap, in: 5...500, step: 5) {
                    LabeledContent("Max messages per hour", value: "\(settings.hourlySendCap)")
                }
                Stepper(value: $settings.secondsBetweenSends, in: 1...60) {
                    LabeledContent("Gap between messages", value: "\(settings.secondsBetweenSends) s")
                }
                Toggle("Fall back to SMS when iMessage fails", isOn: $settings.smsFallback)
            } header: {
                Text("Sending")
            } footer: {
                Text("These sync with the iPhone app. SMS fallback needs Text Message Forwarding from your iPhone to this Mac.")
            }

            Section("Opt-outs") {
                Toggle("Honor STOP replies", isOn: $settings.honorOptOutReplies)
                Toggle("Send a confirmation", isOn: $settings.sendOptOutConfirmation)
                    .disabled(!settings.honorOptOutReplies)
                TextField("Confirmation", text: $settings.optOutConfirmationText, axis: .vertical)
                    .lineLimit(2...4)
                    .disabled(!settings.honorOptOutReplies || !settings.sendOptOutConfirmation)
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

import SwiftUI
import UIKit
import SwiftData
import ReminderCore

/// Home screen: setup that's still missing, what's coming next, what was sent.
struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var texting = TextingAccount.shared

    @Query(sort: \Reminder.createdAt, order: .reverse) private var reminders: [Reminder]
    @Query(sort: \Recipient.createdAt) private var recipients: [Recipient]
    @Query(sort: \RelayHeartbeat.lastSeen, order: .reverse) private var heartbeats: [RelayHeartbeat]
    @Query private var recentDeliveries: [DeliveryRecord]

    @State private var isCreatingReminder = false
    @State private var isEditingNumber = false
    @State private var isShowingPaywall = false
    @State private var alarmAccess = AlarmScheduler.access

    init() {
        var descriptor = FetchDescriptor<DeliveryRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 5
        _recentDeliveries = Query(descriptor)
    }

    private var repository: Repository { Repository(context: modelContext) }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
            .navigationTitle("BlueNudge")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreatingReminder = true
                    } label: {
                        Label("New reminder", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isCreatingReminder) {
                ReminderEditorView(reminder: nil)
            }
            .sheet(isPresented: $isEditingNumber) {
                NavigationStack { MyNumberView() }
            }
            .sheet(isPresented: $isShowingPaywall) { SubscriptionPaywall() }
            .onChange(of: appState.refreshToken) { _, _ in
                alarmAccess = AlarmScheduler.access
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        // Re-read when data changes elsewhere; the token is otherwise unused.
        let _ = appState.refreshToken
        let me = recipients.first
        let active = reminders.filter(\.isActive)
        let usesTexts = active.contains { $0.method == .sms }
        let usesAlarms = active.contains { $0.method == .alarm }
        let usesRelay = active.contains { $0.method == .relay }
        let late = usesRelay ? LateTexts.messages(repository: repository, now: now) : []
        let upcoming = upcomingItems(now: now)
        let recent = Array(ActivityEntry.merged(records: recentDeliveries, texts: texting.recentTexts).prefix(5))

        List {
            if usesTexts {
                textingCard
            }
            if usesAlarms {
                alarmCard
            }
            if usesRelay {
                if me == nil {
                    SetupCard(
                        symbol: "message.badge",
                        title: "Where should your Mac text you?",
                        detail: "Add the phone number or iMessage email your iPhone receives texts on.",
                        actionTitle: "Add my number"
                    ) { isEditingNumber = true }
                } else if let me, me.optedOut {
                    SetupCard(
                        symbol: "pause.circle.fill",
                        tint: .orange,
                        title: "Mac texts are paused",
                        detail: me.optOutSource == "reply"
                            ? "You replied STOP. Reply START to the BlueNudge thread, or resume here."
                            : "Mac texts due while paused are skipped.",
                        actionTitle: "Resume Mac texts",
                        isProminent: false
                    ) {
                        me.setOptedOut(false, source: "manual")
                        repository.save()
                        appState.dataDidChange()
                    }
                }
            }

            if reminders.isEmpty {
                SetupCard(
                    symbol: "bell.badge",
                    title: "Never miss a reminder",
                    detail: "Pick what to be reminded of and when. Get it as a text message, an alarm that rings through silent mode, or a notification.",
                    actionTitle: "Create your first reminder"
                ) { isCreatingReminder = true }
            }

            if usesRelay || !heartbeats.isEmpty {
                Section {
                    RelayStatusView(heartbeat: heartbeats.first)
                } header: {
                    Text("Mac texts are sent by")
                } footer: {
                    if let me {
                        Text("Mac texts go to \(me.displayHandle).")
                    }
                }
            }

            if !late.isEmpty {
                Section {
                    ForEach(late) { message in
                        HStack {
                            Image(systemName: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.reminderTitle.isEmpty ? message.text : message.reminderTitle)
                                    .font(.subheadline.weight(.semibold))
                                Text("Due \(message.occurrence.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Late")
                } footer: {
                    Text("The Mac hasn't sent these yet. Check that it's on, awake and running BlueNudge Relay.")
                }
            }

            if !upcoming.isEmpty {
                Section("Next up") {
                    ForEach(upcoming, id: \.id) { item in
                        UpcomingRow(reminder: item.reminder, date: item.date, now: now)
                    }
                }
            }

            if !recent.isEmpty {
                Section("Recently texted") {
                    ForEach(recent) { entry in
                        DeliveryRow(entry: entry)
                    }
                    Button("See all activity") { appState.selectedTab = .activity }
                }
            }
        }
    }

    /// What's still needed before "Text me" reminders go out.
    @ViewBuilder
    private var textingCard: some View {
        if !texting.isConfigured {
            EmptyView()
        } else if !texting.isSignedIn {
            SetupCard(
                symbol: "message.badge",
                title: "Sign in to get your texts",
                detail: "Your \"Text me\" reminders are ready. Sign in with your phone number to start getting them.",
                actionTitle: "Sign in"
            ) { appState.isShowingTextingSetup = true }
        } else if let status = texting.status, !status.subscribed {
            SetupCard(
                symbol: "message.badge",
                title: "Subscribe to get your texts",
                detail: "Your \"Text me\" reminders go out as soon as the subscription starts.",
                actionTitle: "See plans"
            ) { isShowingPaywall = true }
        } else if texting.textsPaused {
            SetupCard(
                symbol: "pause.circle.fill",
                tint: .orange,
                title: "Texts are paused",
                detail: "Reminders due while paused are skipped. Reply START to BlueNudge, or resume here.",
                actionTitle: "Resume texts",
                isProminent: false
            ) { Task { await texting.setPaused(false) } }
        }
    }

    /// Alarm reminders can't ring until BlueNudge may set alarms.
    @ViewBuilder
    private var alarmCard: some View {
        switch alarmAccess {
        case .notDetermined:
            SetupCard(
                symbol: "alarm",
                title: "Allow alarms",
                detail: "Your alarm reminders can't ring until BlueNudge is allowed to set alarms.",
                actionTitle: "Allow alarms"
            ) {
                Task {
                    await AlarmScheduler.requestAccess()
                    alarmAccess = AlarmScheduler.access
                    appState.dataDidChange()
                }
            }
        case .denied:
            SetupCard(
                symbol: "alarm",
                tint: .orange,
                title: "Alarms are turned off",
                detail: "Turn on alarms for BlueNudge in the Settings app, or switch these reminders to a text or notification.",
                actionTitle: "Open Settings",
                isProminent: false
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .unsupported:
            SetupCard(
                symbol: "alarm",
                tint: .orange,
                title: "Alarms need iOS 26",
                detail: "Update iOS, or switch these reminders to a text or notification.",
                actionTitle: "See reminders",
                isProminent: false
            ) { appState.selectedTab = .reminders }
        case .authorized:
            EmptyView()
        }
    }

    private struct UpcomingItem {
        let id: String
        let reminder: Reminder
        let date: Date
    }

    /// The next few occurrences, at most two per reminder so an hourly one
    /// doesn't crowd out the rest.
    private func upcomingItems(now: Date) -> [UpcomingItem] {
        var byID: [UUID: Reminder] = [:]
        for reminder in reminders { byID[reminder.id] = reminder }
        var perReminder: [UUID: Int] = [:]
        var items: [UpcomingItem] = []
        for item in DuePlanner.upcoming(
            reminders: reminders.map(\.plannerValue),
            method: nil,
            after: now,
            horizon: 14 * 86_400,
            limit: 60
        ) {
            guard let reminder = byID[item.reminderID], perReminder[item.reminderID, default: 0] < 2 else { continue }
            perReminder[item.reminderID, default: 0] += 1
            items.append(UpcomingItem(id: "\(item.reminderID)-\(item.occurrence.timeIntervalSince1970)", reminder: reminder, date: item.occurrence))
            if items.count == 8 { break }
        }
        return items
    }
}

private struct UpcomingRow: View {
    let reminder: Reminder
    let date: Date
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.displayTitle)
                    .font(.subheadline.weight(.semibold))
                if reminder.messageTemplate != reminder.title {
                    Text(reminder.messageTemplate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                MethodBadge(method: reminder.method)
            }
        }
        .padding(.vertical, 2)
    }

    private var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// A card at the top of Today for something that still needs doing.
private struct SetupCard: View {
    let symbol: String
    var tint: Color?
    let title: String
    let detail: String
    let actionTitle: String
    var isProminent = true
    let action: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(tint ?? Color.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if isProminent {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

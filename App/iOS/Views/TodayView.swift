import SwiftUI
import SwiftData
import ReminderCore

/// Home screen: setup that's still missing, what's coming next, what was sent.
struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var appState = AppState.shared

    @Query(sort: \Reminder.createdAt, order: .reverse) private var reminders: [Reminder]
    @Query(sort: \Recipient.createdAt) private var recipients: [Recipient]
    @Query(sort: \RelayHeartbeat.lastSeen, order: .reverse) private var heartbeats: [RelayHeartbeat]
    @Query private var recentDeliveries: [DeliveryRecord]

    @State private var isCreatingReminder = false
    @State private var isEditingNumber = false

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
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        // Re-read when data changes elsewhere; the token is otherwise unused.
        let _ = appState.refreshToken
        let me = recipients.first
        let late = LateTexts.messages(repository: repository, now: now)
        let upcoming = upcomingItems(now: now)
        let usesTexts = reminders.contains { $0.method == .relay && $0.isActive }

        List {
            if me == nil {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Where should reminders be texted?", systemImage: "message.badge")
                            .font(.headline)
                        Text("Add the phone number or iMessage email your iPhone receives texts on.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Add my number") { isEditingNumber = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 6)
                }
            } else if me?.optedOut == true {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Texts are paused", systemImage: "pause.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(me?.optOutSource == "reply"
                             ? "You replied STOP. Reply START to the BlueNudge thread, or resume here."
                             : "Reminders due while paused are skipped. Notification reminders still arrive.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Resume texts") {
                            me?.setOptedOut(false, source: "manual")
                            repository.save()
                            appState.dataDidChange()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }

            if reminders.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Get your reminders as texts")
                            .font(.headline)
                        Text("Pick what to be reminded of and when. The reminder lands in Messages like any other text, so it's hard to miss and easy to find later.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Create your first reminder") { isCreatingReminder = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 6)
                }
            }

            if usesTexts || !heartbeats.isEmpty {
                Section {
                    RelayStatusView(heartbeat: heartbeats.first)
                } header: {
                    Text("Texts are sent by")
                } footer: {
                    if let me {
                        Text("Texts go to \(me.displayHandle).")
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

            if !recentDeliveries.isEmpty {
                Section("Recently texted") {
                    ForEach(recentDeliveries) { record in
                        DeliveryRow(record: record)
                    }
                    Button("See all activity") { appState.selectedTab = .activity }
                }
            }
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

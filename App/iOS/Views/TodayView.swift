import SwiftUI
import SwiftData
import MessageUI
import ReminderCore

/// Home screen: what needs attention now and what is coming up.
struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var appState = AppState.shared

    @Query(sort: \Reminder.createdAt, order: .reverse) private var reminders: [Reminder]
    @Query(sort: \Recipient.name) private var recipients: [Recipient]
    @Query(sort: \RelayHeartbeat.lastSeen, order: .reverse) private var heartbeats: [RelayHeartbeat]
    @Query private var recentDeliveries: [DeliveryRecord]

    @State private var composing: PlannedMessage?
    @State private var isCreatingReminder = false

    init() {
        var descriptor = FetchDescriptor<DeliveryRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 6
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
            .messageComposer($composing) { message, result in
                if result == .sent {
                    SendQueue.record(message, status: .sent, note: "Sent from iPhone because the relay was late", repository: repository)
                }
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        // Re-read when data changes elsewhere; the token is otherwise unused.
        let _ = appState.refreshToken
        let due = SendQueue.dueMessages(repository: repository, now: now)
        let overdue = SendQueue.overdueRelayMessages(repository: repository, now: now)
        let upcoming = upcomingItems(now: now)
        let directory = Dictionary(recipients.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hasRelayReminders = reminders.contains { $0.method == .relay && $0.isActive }

        List {
            if reminders.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Send reminders by iMessage for free")
                            .font(.headline)
                        Text("Add the people you remind, write the message once, pick a schedule. BlueNudge handles the rest through the Messages app, so there are no per-text fees.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Create your first reminder") { isCreatingReminder = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 6)
                }
            }

            if !due.isEmpty {
                Section {
                    Button {
                        appState.presentSendQueue()
                    } label: {
                        HStack {
                            Image(systemName: "paperplane.circle.fill")
                                .font(.title)
                            VStack(alignment: .leading) {
                                Text(due.count == 1 ? "1 message ready to send" : "\(due.count) messages ready to send")
                                    .font(.headline)
                                Text("Tap to review and send")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if hasRelayReminders || !heartbeats.isEmpty {
                Section("Mac relay") {
                    RelayStatusView(heartbeat: heartbeats.first)
                    if !overdue.isEmpty {
                        ForEach(overdue) { message in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Late: \(message.recipientName.isEmpty ? message.handle : message.recipientName)")
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(message.reminderTitle) · due \(message.occurrence.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Send from iPhone") { composing = message }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            if !upcoming.isEmpty {
                Section("Upcoming") {
                    ForEach(upcoming, id: \.id) { item in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading) {
                                Text(item.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.date.formatted(date: .omitted, time: .shortened))
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                            }
                            .frame(width: 76, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.reminder.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                Text(RecipientSummary.text(for: item.reminder.recipientIDs, in: directory))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                MethodBadge(method: item.reminder.method)
                            }
                        }
                    }
                }
            }

            if !recentDeliveries.isEmpty {
                Section("Recent activity") {
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

    private func upcomingItems(now: Date) -> [UpcomingItem] {
        var byID: [UUID: Reminder] = [:]
        for reminder in reminders { byID[reminder.id] = reminder }
        return DuePlanner.upcoming(
            reminders: reminders.map(\.plannerValue),
            method: nil,
            after: now,
            horizon: 14 * 86_400,
            limit: 12
        ).compactMap { item in
            guard let reminder = byID[item.reminderID] else { return nil }
            return UpcomingItem(id: "\(item.reminderID)-\(item.occurrence.timeIntervalSince1970)", reminder: reminder, date: item.occurrence)
        }
    }
}

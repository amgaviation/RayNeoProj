import SwiftUI
import SwiftData
import ReminderCore

struct RemindersListView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var appState = AppState.shared

    @Query(sort: \Reminder.createdAt, order: .reverse) private var reminders: [Reminder]
    @Query(sort: \Recipient.name) private var recipients: [Recipient]

    @State private var isCreating = false
    @State private var editing: Reminder?
    @State private var searchText = ""

    private var repository: Repository { Repository(context: modelContext) }

    var body: some View {
        NavigationStack {
            let directory = Dictionary(recipients.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let now = Date()
            let filtered = reminders.filter(matchesSearch)
            let active = filtered.filter { $0.isActive && !$0.schedule.isFinished(after: now) }
            let inactive = filtered.filter { !($0.isActive && !$0.schedule.isFinished(after: now)) }

            List {
                if reminders.isEmpty {
                    ContentUnavailableView {
                        Label("No reminders yet", systemImage: "bell.badge")
                    } description: {
                        Text("Create a reminder to message one person or a whole group on a schedule.")
                    } actions: {
                        Button("New reminder") { isCreating = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if !active.isEmpty {
                    Section("Active") {
                        ForEach(active) { reminder in
                            row(reminder, directory: directory, now: now)
                        }
                    }
                }
                if !inactive.isEmpty {
                    Section("Paused or finished") {
                        ForEach(inactive) { reminder in
                            row(reminder, directory: directory, now: now)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search reminders")
            .navigationTitle("Reminders")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreating = true
                    } label: {
                        Label("New reminder", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isCreating) {
                ReminderEditorView(reminder: nil)
            }
            .sheet(item: $editing) { reminder in
                ReminderEditorView(reminder: reminder)
            }
        }
    }

    private func matchesSearch(_ reminder: Reminder) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return reminder.title.localizedCaseInsensitiveContains(query)
            || reminder.messageTemplate.localizedCaseInsensitiveContains(query)
    }

    private func row(_ reminder: Reminder, directory: [UUID: Recipient], now: Date) -> some View {
        Button {
            editing = reminder
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(reminder.displayTitle)
                        .font(.headline)
                        .foregroundStyle(reminder.isActive ? Color.primary : Color.secondary)
                    Spacer()
                    MethodBadge(method: reminder.method)
                }
                Text(reminder.schedule.summary())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(RecipientSummary.text(for: reminder.recipientIDs, in: directory))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let next = reminder.nextOccurrence(after: now) {
                    Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                } else if !reminder.isActive {
                    Text("Paused").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Finished").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                repository.delete(reminder)
                appState.dataDidChange()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                toggle(reminder)
            } label: {
                Label(reminder.isActive ? "Pause" : "Resume", systemImage: reminder.isActive ? "pause" : "play")
            }
            .tint(reminder.isActive ? .orange : .green)
        }
        .contextMenu {
            Button(reminder.isActive ? "Pause" : "Resume", systemImage: reminder.isActive ? "pause" : "play") {
                toggle(reminder)
            }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                duplicate(reminder)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                repository.delete(reminder)
                appState.dataDidChange()
            }
        }
    }

    private func toggle(_ reminder: Reminder) {
        reminder.isActive.toggle()
        if reminder.isActive {
            // Resuming never back-fills occurrences that passed while paused.
            reminder.activeSince = Date()
        }
        reminder.updatedAt = Date()
        repository.save()
        appState.dataDidChange()
    }

    private func duplicate(_ reminder: Reminder) {
        let copy = Reminder(
            title: reminder.title + " (copy)",
            messageTemplate: reminder.messageTemplate,
            schedule: reminder.schedule,
            recipientIDs: reminder.recipientIDs,
            method: reminder.method
        )
        copy.isActive = false
        modelContext.insert(copy)
        repository.save()
        appState.dataDidChange()
    }
}

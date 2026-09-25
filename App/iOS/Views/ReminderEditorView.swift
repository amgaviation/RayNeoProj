import SwiftUI
import SwiftData
import ReminderCore

/// Create or edit a reminder: message, recipients, schedule and delivery method.
struct ReminderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var appState = AppState.shared

    @Query(sort: \Recipient.name) private var allRecipients: [Recipient]
    @Query(sort: \RelayHeartbeat.lastSeen, order: .reverse) private var heartbeats: [RelayHeartbeat]

    let reminder: Reminder?

    @State private var title = ""
    @State private var message = ""
    @State private var recipientIDs: [UUID] = []
    @State private var frequency: Schedule.Frequency = .once
    @State private var start = Date().addingTimeInterval(3_600)
    @State private var interval = 1
    @State private var weekdays: Set<Int> = []
    @State private var endMode: EndMode = .never
    @State private var endDate = Date().addingTimeInterval(30 * 86_400)
    @State private var endCount = 10
    @State private var method: DeliveryMethod = .tapToSend
    @State private var isActive = true
    @State private var hasLoaded = false
    @State private var isConfirmingDelete = false

    enum EndMode: String, CaseIterable, Identifiable {
        case never, onDate, afterCount
        var id: String { rawValue }
        var title: String {
            switch self {
            case .never: return "Never"
            case .onDate: return "On a date"
            case .afterCount: return "After a number of times"
            }
        }
    }

    init(reminder: Reminder?) {
        self.reminder = reminder
    }

    private var repository: Repository { Repository(context: modelContext) }

    private var directory: [UUID: Recipient] {
        Dictionary(allRecipients.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var draftSchedule: Schedule {
        let end: Schedule.End
        switch endMode {
        case .never: end = .never
        case .onDate: end = .on(Self.endOfDay(endDate))
        case .afterCount: end = .after(max(1, endCount))
        }
        return Schedule(
            frequency: frequency,
            start: start,
            interval: interval,
            weekdays: frequency == .weekly ? weekdays.sorted() : [],
            end: end,
            timeZoneIdentifier: TimeZone.current.identifier
        ).truncatedToMinute()
    }

    private var canSave: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recipientIDs.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (only you see this)", text: $title)
                }

                messageSection
                recipientsSection
                scheduleSection
                deliverySection

                if reminder != nil {
                    Section {
                        Toggle("Active", isOn: $isActive)
                    } footer: {
                        Text("Paused reminders keep their settings but send nothing. Resuming never sends the ones that passed while paused.")
                    }
                    Section {
                        Button("Delete reminder", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                }
            }
            .navigationTitle(reminder == nil ? "New Reminder" : "Edit Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: loadIfNeeded)
            .confirmationDialog("Delete this reminder?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let reminder {
                        repository.delete(reminder)
                        appState.dataDidChange()
                    }
                    dismiss()
                }
            } message: {
                Text("Its delivery history stays in Activity.")
            }
        }
    }

    // MARK: Sections

    private var messageSection: some View {
        Section {
            TextEditor(text: $message)
                .frame(minHeight: 110)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TemplateRenderer.tokens) { token in
                        Button(token.placeholder) { insert(token) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Message")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                let unknown = TemplateRenderer.unknownTokens(in: message)
                if !unknown.isEmpty {
                    Text("Not recognised and sent as typed: \(unknown.map { "{\($0)}" }.joined(separator: ", "))")
                        .foregroundStyle(.orange)
                }
                if !message.isEmpty {
                    Text("Preview: \(previewText)")
                }
            }
        }
    }

    private var recipientsSection: some View {
        Section {
            NavigationLink {
                RecipientPickerView(selection: $recipientIDs)
            } label: {
                HStack {
                    Text("Recipients")
                    Spacer()
                    Text(recipientIDs.isEmpty ? "Choose" : "\(recipientIDs.count) selected")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(recipientIDs, id: \.self) { id in
                if let recipient = directory[id] {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(recipient.displayName)
                            Text(recipient.displayHandle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if recipient.optedOut {
                            Text("Opted out").font(.caption).foregroundStyle(.purple)
                        } else if !recipient.hasValidHandle {
                            Text("Invalid number").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            .onDelete { offsets in
                recipientIDs.remove(atOffsets: offsets)
            }
        } header: {
            Text("Send to")
        } footer: {
            Text("Each person gets their own private message, never a group chat.")
        }
    }

    private var scheduleSection: some View {
        Section {
            Picker("Repeat", selection: $frequency) {
                ForEach(Schedule.Frequency.allCases) { frequency in
                    Text(frequency.title).tag(frequency)
                }
            }
            DatePicker(selection: $start) {
                Text(frequency == .once ? "Date & time" : "Starts")
            }

            if frequency != .once {
                Stepper(value: $interval, in: 1...99) {
                    Text(interval == 1 ? "Every \(frequency.unit(plural: false))" : "Every \(interval) \(frequency.unit(plural: true))")
                }
            }

            if frequency == .weekly {
                WeekdayPicker(selection: $weekdays, fallback: Calendar.current.component(.weekday, from: start))
            }

            if frequency != .once {
                Picker("Ends", selection: $endMode) {
                    ForEach(EndMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                switch endMode {
                case .never:
                    EmptyView()
                case .onDate:
                    DatePicker("End date", selection: $endDate, displayedComponents: .date)
                case .afterCount:
                    Stepper(value: $endCount, in: 1...999) {
                        Text(endCount == 1 ? "1 time" : "\(endCount) times")
                    }
                }
            }
        } header: {
            Text("Schedule")
        } footer: {
            let schedule = draftSchedule
            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.summary())
                ForEach(schedule.validationIssues(), id: \.self) { issue in
                    Text(issue).foregroundStyle(.orange)
                }
                let next = schedule.upcoming(from: Self.startOfCurrentMinute(), count: 3)
                if !next.isEmpty {
                    Text("Next: " + next.map { $0.formatted(date: .abbreviated, time: .shortened) }.joined(separator: " · "))
                }
            }
        }
    }

    private var deliverySection: some View {
        Section {
            Picker("Delivery", selection: $method) {
                ForEach(DeliveryMethod.allCases) { method in
                    Label(method.title, systemImage: method.symbolName).tag(method)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("How it's sent")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(method.explanation)
                if method == .relay {
                    if let heartbeat = heartbeats.first {
                        Text(heartbeat.isOnline() ? "Relay online on \(heartbeat.deviceName)." : "Relay last seen \(heartbeat.lastSeen.formatted(.relative(presentation: .named))) on \(heartbeat.deviceName).")
                            .foregroundStyle(heartbeat.isOnline() ? Color.green : Color.orange)
                    } else {
                        Text("No relay Mac has checked in yet. Until one does, these will show as late on the Today screen with a Send from iPhone button.")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private var previewText: String {
        let first = recipientIDs.first.flatMap { directory[$0] }
        let settings = repository.existingSettings()?.renderSettings() ?? RenderSettings()
        let schedule = draftSchedule
        let occurrence = schedule.upcoming(from: Self.startOfCurrentMinute(), count: 1).first ?? schedule.start
        return TemplateRenderer.render(
            template: message,
            recipientName: first?.name ?? "Alex Rivera",
            reminderTitle: resolvedTitle,
            occurrence: occurrence,
            timeZone: schedule.timeZone,
            settings: settings
        )
    }

    private var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = message.split(separator: "\n").first.map(String.init) ?? ""
        return String(firstLine.prefix(40)).trimmingCharacters(in: .whitespaces)
    }

    private func insert(_ token: TemplateRenderer.Token) {
        if !message.isEmpty, let last = message.last, !last.isWhitespace {
            message += " "
        }
        message += token.placeholder
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let reminder else {
            method = repository.settings().defaultMethod
            start = Self.nextRoundHour()
            return
        }
        title = reminder.title
        message = reminder.messageTemplate
        recipientIDs = reminder.recipientIDs
        method = reminder.method
        isActive = reminder.isActive
        let schedule = reminder.schedule
        frequency = schedule.frequency
        start = schedule.start
        interval = schedule.normalizedInterval
        weekdays = Set(schedule.frequency == .weekly ? schedule.effectiveWeekdays : [])
        switch schedule.end {
        case .never:
            endMode = .never
        case .on(let date):
            endMode = .onDate
            endDate = date
        case .after(let count):
            endMode = .afterCount
            endCount = count
        }
    }

    private func save() {
        let schedule = draftSchedule
        let now = Self.startOfCurrentMinute()
        if let reminder {
            let timingChanged = reminder.schedule != schedule
                || reminder.recipientIDs != recipientIDs
                || reminder.method != method
                || (!reminder.isActive && isActive)
            reminder.title = resolvedTitle
            reminder.messageTemplate = message
            reminder.schedule = schedule
            reminder.recipientIDs = recipientIDs
            reminder.method = method
            reminder.isActive = isActive
            if timingChanged {
                // Never back-fill: occurrences before this edit are not sent.
                reminder.activeSince = now
            }
            reminder.updatedAt = Date()
        } else {
            let created = Reminder(
                title: resolvedTitle,
                messageTemplate: message,
                schedule: schedule,
                recipientIDs: recipientIDs,
                method: method
            )
            created.activeSince = now
            modelContext.insert(created)
        }
        repository.save()
        appState.dataDidChange()
        if method == .tapToSend {
            Task {
                if await NotificationScheduler.authorizationStatus() == .notDetermined {
                    await NotificationScheduler.requestAuthorization()
                    appState.dataDidChange()
                }
            }
        }
        dismiss()
    }

    // MARK: Dates

    static func startOfCurrentMinute() -> Date {
        let seconds = Date().timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60)
    }

    static func nextRoundHour() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? now
    }

    static func endOfDay(_ date: Date) -> Date {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: dayStart) ?? date
    }
}

/// Seven toggles for choosing weekdays, in the user's locale order.
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    /// Shown as selected when nothing is chosen (the start date's weekday).
    let fallback: Int

    var body: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        HStack {
            ForEach(order, id: \.self) { weekday in
                let isOn = selection.isEmpty ? weekday == fallback : selection.contains(weekday)
                Button {
                    toggle(weekday)
                } label: {
                    Text(symbols[weekday - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.weekdaySymbols[weekday - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
                if weekday != order.last { Spacer(minLength: 0) }
            }
        }
        .padding(.vertical, 4)
    }

    private func toggle(_ weekday: Int) {
        if selection.isEmpty {
            selection = [fallback]
        }
        if selection.contains(weekday) {
            if selection.count > 1 { selection.remove(weekday) }
        } else {
            selection.insert(weekday)
        }
    }
}

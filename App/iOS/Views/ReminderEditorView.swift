import SwiftUI
import UIKit
import SwiftData
import ReminderCore

/// Create or edit a reminder: what it says, when, and how it reaches you.
struct ReminderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var texting = TextingAccount.shared

    @Query(sort: \Recipient.createdAt) private var recipients: [Recipient]
    @Query(sort: \RelayHeartbeat.lastSeen, order: .reverse) private var heartbeats: [RelayHeartbeat]

    let reminder: Reminder?

    @State private var title = ""
    @State private var message = ""
    @State private var frequency: Schedule.Frequency = .once
    @State private var start = Date().addingTimeInterval(3_600)
    @State private var interval = 1
    @State private var weekdays: Set<Int> = []
    @State private var limitHours = true
    @State private var activeFrom = ReminderEditorView.clock(9 * 60)
    @State private var activeTo = ReminderEditorView.clock(21 * 60)
    @State private var endMode: EndMode = .never
    @State private var endDate = Date().addingTimeInterval(30 * 86_400)
    @State private var endCount = 10
    @State private var method: DeliveryMethod = .notification
    @State private var isActive = true
    @State private var hasLoaded = false
    @State private var isConfirmingDelete = false
    @State private var isEditingNumber = false
    @State private var isShowingTextingSetup = false
    @State private var isShowingPaywall = false
    @State private var alarmAccess = AlarmScheduler.access

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

    /// Placeholders that make sense in a text to yourself.
    private static let tokens = TemplateRenderer.tokens.filter { ["time", "date", "weekday", "title"].contains($0.name) }

    init(reminder: Reminder?) {
        self.reminder = reminder
    }

    private var repository: Repository { Repository(context: modelContext) }

    private var me: Recipient? { recipients.first }

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
            end: frequency == .once ? .never : end,
            timeZoneIdentifier: TimeZone.current.identifier,
            activeMinutes: frequency == .hourly && limitHours ? Self.minutes(activeFrom)...max(Self.minutes(activeFrom), Self.minutes(activeTo)) : nil
        ).truncatedToMinute()
    }

    private var canSave: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                messageSection
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
            .sheet(isPresented: $isEditingNumber) {
                NavigationStack { MyNumberView() }
            }
            .sheet(isPresented: $isShowingTextingSetup) { TextingSetupSheet() }
            .sheet(isPresented: $isShowingPaywall) { SubscriptionPaywall() }
            .confirmationDialog("Delete this reminder?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let reminder {
                        repository.delete(reminder)
                        appState.dataDidChange()
                    }
                    dismiss()
                }
            } message: {
                Text("Its history stays in Activity.")
            }
        }
    }

    // MARK: Sections

    private var messageSection: some View {
        Section {
            TextField("Remind me to…", text: $message, axis: .vertical)
                .lineLimit(2...6)
            TextField("Short title (optional)", text: $title)
            Menu {
                ForEach(Self.tokens) { token in
                    Button {
                        insert(token)
                    } label: {
                        Text("\(token.placeholder)  \(token.summary)")
                    }
                }
            } label: {
                Label("Insert time or date", systemImage: "curlybraces")
            }
        } header: {
            Text("Text")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                let unknown = TemplateRenderer.unknownTokens(in: message)
                if !unknown.isEmpty {
                    Text("Not recognised and sent as typed: \(unknown.map { "{\($0)}" }.joined(separator: ", "))")
                        .foregroundStyle(.orange)
                }
                if !message.isEmpty {
                    Text("You'll get: \(previewText)")
                }
            }
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
                Text(frequency == .once ? "When" : "Starts")
            }
            if frequency == .once {
                Menu {
                    ForEach(QuickTime.allCases) { quick in
                        Button(quick.title) { start = quick.date() }
                    }
                } label: {
                    Label("Quick times", systemImage: "clock.arrow.circlepath")
                }
            }

            if frequency != .once {
                Stepper(value: $interval, in: 1...99) {
                    Text(interval == 1 ? "Every \(frequency.unit(plural: false))" : "Every \(interval) \(frequency.unit(plural: true))")
                }
            }

            if frequency == .weekly {
                WeekdayPicker(selection: $weekdays, fallback: Calendar.current.component(.weekday, from: start))
            }

            if frequency == .hourly {
                Toggle("Only during the day", isOn: $limitHours)
                if limitHours {
                    DatePicker("From", selection: $activeFrom, displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: $activeTo, displayedComponents: .hourAndMinute)
                }
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
            Text("When")
        } footer: {
            let schedule = draftSchedule
            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.summary())
                if frequency == .hourly, limitHours, Self.minutes(activeTo) < Self.minutes(activeFrom) {
                    Text("\"Until\" is earlier than \"From\", so only the From time is used.")
                        .foregroundStyle(.orange)
                }
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

    private var availableMethods: [DeliveryMethod] {
        DeliveryMethod.available(hasRelay: !heartbeats.isEmpty, including: reminder?.method)
    }

    private var deliverySection: some View {
        Section {
            Picker("Delivery", selection: $method) {
                ForEach(availableMethods) { method in
                    Label(method.title, systemImage: method.symbolName).tag(method)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            switch method {
            case .sms: textStatusRow
            case .alarm: alarmStatusRow
            case .relay: relayNumberRow
            case .notification: EmptyView()
            }
        } header: {
            Text("How")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(method.explanation)
                deliveryNote
            }
        }
    }

    @ViewBuilder
    private var textStatusRow: some View {
        if !texting.isSignedIn {
            Button {
                isShowingTextingSetup = true
            } label: {
                Label("Sign in to get texts", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        } else if texting.status != nil, !texting.isSubscribed {
            Button {
                isShowingPaywall = true
            } label: {
                Label("Subscribe to get texts", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Button {
                isShowingTextingSetup = true
            } label: {
                LabeledContent("Texts go to", value: HandleNormalizer.displayFormat(texting.session?.phone ?? ""))
            }
            .foregroundStyle(Color.primary)
        }
    }

    @ViewBuilder
    private var alarmStatusRow: some View {
        switch alarmAccess {
        case .notDetermined:
            Button("Allow alarms") {
                Task {
                    await AlarmScheduler.requestAccess()
                    alarmAccess = AlarmScheduler.access
                    appState.dataDidChange()
                }
            }
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Label("Alarms are off. Turn them on in Settings", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        case .unsupported:
            Label("Alarms need iOS 26 or later", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .authorized:
            EmptyView()
        }
    }

    private var relayNumberRow: some View {
        Button {
            isEditingNumber = true
        } label: {
            if let me {
                LabeledContent("Texts go to", value: me.displayHandle)
            } else {
                Label("Add the number to text", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .foregroundStyle(Color.primary)
    }

    @ViewBuilder
    private var deliveryNote: some View {
        switch method {
        case .sms:
            if texting.textsPaused {
                Text("Texts are paused. Turn them back on in Settings › Texts.")
                    .foregroundStyle(.orange)
            }
        case .relay:
            if let heartbeat = heartbeats.first {
                Text(heartbeat.isOnline() ? "Relay online on \(heartbeat.deviceName)." : "Relay last seen \(heartbeat.lastSeen.formatted(.relative(presentation: .named))) on \(heartbeat.deviceName).")
                    .foregroundStyle(heartbeat.isOnline() ? Color.green : Color.orange)
            } else {
                Text("No Mac relay has checked in yet. Texts wait until one does, and show as late on the Today screen.")
                    .foregroundStyle(.orange)
            }
        case .alarm:
            if alarmAccess == .authorized {
                Text("The next \(AlarmScheduler.maxScheduled) alarms are set ahead and topped up whenever BlueNudge opens.")
            }
        case .notification:
            EmptyView()
        }
    }

    // MARK: Actions

    private var previewText: String {
        let settings = repository.existingSettings()?.renderSettings() ?? RenderSettings()
        let schedule = draftSchedule
        let occurrence = schedule.upcoming(from: Self.startOfCurrentMinute(), count: 1).first ?? schedule.start
        return TemplateRenderer.render(
            template: message,
            recipientName: me?.name ?? "",
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
            let preferred = repository.existingSettings()?.defaultMethod ?? .notification
            method = availableMethods.contains(preferred) ? preferred : (availableMethods.first ?? .notification)
            start = Self.nextRoundHour()
            return
        }
        title = reminder.title
        message = reminder.messageTemplate
        method = reminder.method
        isActive = reminder.isActive
        let schedule = reminder.schedule
        frequency = schedule.frequency
        start = schedule.start
        interval = schedule.normalizedInterval
        weekdays = Set(schedule.frequency == .weekly ? schedule.effectiveWeekdays : [])
        if schedule.frequency == .hourly {
            if let window = schedule.activeMinutes {
                limitHours = true
                activeFrom = Self.clock(window.lowerBound)
                activeTo = Self.clock(window.upperBound)
            } else {
                limitHours = false
            }
        }
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
        let recipientIDs = me.map { [$0.id] } ?? reminder?.recipientIDs ?? []
        if let reminder {
            let timingChanged = reminder.schedule != schedule
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
        switch method {
        case .notification:
            Task {
                if await NotificationScheduler.authorizationStatus() == .notDetermined {
                    await NotificationScheduler.requestAuthorization()
                    appState.dataDidChange()
                }
            }
        case .alarm:
            if AlarmScheduler.access == .notDetermined {
                Task {
                    await AlarmScheduler.requestAccess()
                    appState.dataDidChange()
                }
            }
        case .sms, .relay:
            break
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

    /// Today at `minutes` after midnight.
    static func clock(_ minutes: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }

    /// Minutes after midnight for a time of day.
    static func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

/// Shortcuts for one-time reminders.
enum QuickTime: String, CaseIterable, Identifiable {
    case tenMinutes, oneHour, thisEvening, tomorrowMorning, nextMonday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tenMinutes: return "In 10 minutes"
        case .oneHour: return "In 1 hour"
        case .thisEvening: return "This evening (6 PM)"
        case .tomorrowMorning: return "Tomorrow morning (9 AM)"
        case .nextMonday: return "Next Monday (9 AM)"
        }
    }

    func date(now: Date = Date(), calendar: Calendar = .current) -> Date {
        func minuteRounded(_ date: Date) -> Date {
            let seconds = date.timeIntervalSinceReferenceDate
            return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.up) * 60)
        }
        func at(_ hour: Int, daysFromToday days: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        switch self {
        case .tenMinutes:
            return minuteRounded(now.addingTimeInterval(10 * 60))
        case .oneHour:
            return minuteRounded(now.addingTimeInterval(3_600))
        case .thisEvening:
            let evening = at(18, daysFromToday: 0)
            return evening > now ? evening : at(18, daysFromToday: 1)
        case .tomorrowMorning:
            return at(9, daysFromToday: 1)
        case .nextMonday:
            let weekday = calendar.component(.weekday, from: now)
            let days = (2 - weekday + 7) % 7
            return at(9, daysFromToday: days == 0 ? 7 : days)
        }
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

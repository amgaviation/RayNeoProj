import SwiftUI
import SwiftData
import ReminderCore

struct RootView: View {
    @ObservedObject private var appState = AppState.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var demoEditorReminder: Reminder?
    @State private var didApplyDemoScreen = false

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(AppState.Tab.today)
            RemindersListView()
                .tabItem { Label("Reminders", systemImage: "bell") }
                .tag(AppState.Tab.reminders)
            ActivityView()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                .tag(AppState.Tab.activity)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppState.Tab.settings)
        }
        .fullScreenCover(isPresented: $appState.isShowingOnboarding) {
            OnboardingView()
        }
        .sheet(isPresented: $appState.isShowingTextingSetup) {
            TextingSetupSheet()
        }
        .sheet(item: $demoEditorReminder) { reminder in
            ReminderEditorView(reminder: reminder)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await appState.appDidBecomeActive() }
            }
        }
        .task {
            await appState.appDidBecomeActive()
            await openDemoScreenIfNeeded()
        }
    }

    /// Demo mode only: open the screen named by `-BlueNudgeScreen`.
    @MainActor
    private func openDemoScreenIfNeeded() async {
        guard DemoMode.isEnabled, !didApplyDemoScreen else { return }
        didApplyDemoScreen = true
        switch DemoMode.screen {
        case "reminders":
            appState.selectedTab = .reminders
        case "activity":
            appState.selectedTab = .activity
        case "settings":
            appState.selectedTab = .settings
        case "editor", "how":
            appState.selectedTab = .reminders
            // Let the tab settle before presenting over it.
            try? await Task.sleep(nanoseconds: 600_000_000)
            let title = DemoMode.screen == "how" ? DemoData.deliveryReminderTitle : DemoData.editorReminderTitle
            demoEditorReminder = Repository(context: DataStore.shared.mainContext)
                .reminders()
                .first { $0.title == title }
        case "onboarding", "delivery":
            appState.isShowingOnboarding = true
        case "texts":
            appState.selectedTab = .settings
            try? await Task.sleep(nanoseconds: 600_000_000)
            appState.isShowingTextingSetup = true
        default:
            appState.selectedTab = .today
        }
    }
}

/// First run: what the app does and how reminders should reach you.
struct OnboardingView: View {
    @ObservedObject private var appState = AppState.shared
    @Environment(\.modelContext) private var modelContext

    private enum Page: Int {
        case welcome, delivery
    }

    // Demo mode can open straight on the second page for screenshots.
    @State private var page: Page = DemoMode.isEnabled && DemoMode.screen == "delivery" ? .delivery : .welcome
    @State private var choice: DeliveryMethod? = DemoMode.isEnabled && DemoMode.screen == "delivery" ? .sms : nil

    private var repository: Repository { Repository(context: modelContext) }

    /// The ways this iPhone can get reminders without a Mac.
    private var choices: [DeliveryMethod] {
        DeliveryMethod.available(hasRelay: false).filter { $0 != .relay }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView {
                    Group {
                        switch page {
                        case .welcome: welcome
                        case .delivery: delivery
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }

                PageDots(count: 2, current: page.rawValue)

                Button(action: advance) {
                    Text(page == .delivery ? "Get started" : "Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(page == .delivery && choice == nil)
                .padding(.horizontal, 24)
            }
            .padding(.bottom)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if page != .welcome {
                        Button("Back") { withAnimation { page = .welcome } }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Skip") { complete() }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Reminders you won't miss")
                .font(.largeTitle.bold())
            Text("BlueNudge reminds you the way that's hardest to ignore: a text message, an alarm or a notification.")
                .foregroundStyle(.secondary)
            FeatureLine(symbol: "calendar.badge.clock", text: "Once, hourly, daily, weekly, monthly or yearly, with quiet hours for hourly ones.")
            FeatureLine(symbol: "message.fill", text: "Texts land in Messages. Reply SNOOZE to get one again later, or STOP to pause.")
            FeatureLine(symbol: "alarm.fill", text: "Alarms ring through silent mode and Focus until you stop them.")
            FeatureLine(symbol: "icloud.fill", text: "Your reminders stay on your iPhone and in your private iCloud.")
        }
    }

    private var delivery: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How should reminders reach you?")
                .font(.title.bold())
            Text("This is the default for new reminders. Each reminder can use its own.")
                .foregroundStyle(.secondary)
            ForEach(choices) { method in
                ChoiceCard(
                    title: method.title,
                    detail: Self.pitch(for: method),
                    symbol: method.symbolName,
                    isSelected: choice == method
                ) { choice = method }
            }
        }
    }

    private static func pitch(for method: DeliveryMethod) -> String {
        switch method {
        case .sms: return "A real text message from BlueNudge. Reply SNOOZE to get it again. Subscription."
        case .alarm: return "Rings like an alarm, even on silent, until you stop it. Free."
        case .notification: return "A notification on this iPhone. Free."
        case .relay: return "An iMessage from your own Mac. Free."
        }
    }

    private func advance() {
        if page == .delivery {
            complete()
        } else {
            withAnimation { page = .delivery }
        }
    }

    private func complete() {
        let settings = repository.settings()
        if let choice {
            settings.defaultMethod = choice
            settings.updatedAt = Date()
        } else if settings.defaultMethod == .relay {
            // Skipped: don't default to a Mac nobody set up.
            settings.defaultMethod = .notification
        }
        repository.save()
        appState.completeOnboarding()
        let chosen = choice
        Task {
            switch chosen {
            case .sms:
                // Let the full-screen cover finish closing first.
                try? await Task.sleep(nanoseconds: 700_000_000)
                appState.isShowingTextingSetup = true
            case .alarm:
                await AlarmScheduler.requestAccess()
            case .notification:
                await NotificationScheduler.requestAuthorization()
            case .relay, nil:
                break
            }
            appState.dataDidChange()
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ChoiceCard: View {
    let title: String
    let detail: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

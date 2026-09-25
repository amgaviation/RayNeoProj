import SwiftUI
import SwiftData

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
            PeopleListView()
                .tabItem { Label("People", systemImage: "person.2") }
                .tag(AppState.Tab.people)
            ActivityView()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                .tag(AppState.Tab.activity)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppState.Tab.settings)
        }
        .sheet(isPresented: $appState.isShowingSendQueue) {
            SendQueueView()
        }
        .fullScreenCover(isPresented: $appState.isShowingOnboarding) {
            OnboardingView()
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
            openDemoScreenIfNeeded()
        }
    }

    /// Demo mode only: open the screen named by `-BlueNudgeScreen`.
    private func openDemoScreenIfNeeded() {
        guard DemoMode.isEnabled, !didApplyDemoScreen else { return }
        didApplyDemoScreen = true
        switch DemoMode.screen {
        case "reminders":
            appState.selectedTab = .reminders
        case "people":
            appState.selectedTab = .people
        case "activity":
            appState.selectedTab = .activity
        case "settings":
            appState.selectedTab = .settings
        case "queue":
            appState.presentSendQueue()
        case "editor":
            appState.selectedTab = .reminders
            demoEditorReminder = Repository(context: DataStore.shared.mainContext)
                .reminders()
                .first { $0.title == DemoData.editorReminderTitle }
        case "onboarding":
            appState.isShowingOnboarding = true
        default:
            appState.selectedTab = .today
        }
    }
}

/// First-run walkthrough: how it works, which delivery mode fits, permissions.
struct OnboardingView: View {
    @ObservedObject private var appState = AppState.shared
    @Environment(\.modelContext) private var modelContext

    @State private var page = 0
    @State private var hasMac: Bool?
    @State private var senderName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TabView(selection: $page) {
                    welcome.tag(0)
                    delivery.tag(1)
                    finish.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button(action: advance) {
                    Text(page == 2 ? "Get started" : "Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(page == 1 && hasMac == nil)
                .padding(.horizontal)
            }
            .padding(.bottom)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { complete() }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                Text("Reminders by iMessage, with no per-text fees")
                    .font(.largeTitle.bold())
                Text("Schedule a message once and BlueNudge sends it to each person privately through the Messages app, from your own number or Apple Account.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                FeatureLine(symbol: "calendar.badge.clock", text: "One-time or repeating: hourly, daily, weekly, monthly, yearly.")
                FeatureLine(symbol: "person.2.fill", text: "Personalised for each person with {first_name}, {date}, {time}.")
                FeatureLine(symbol: "hand.raised.fill", text: "STOP replies are honored automatically by the Mac relay.")
                FeatureLine(symbol: "icloud.fill", text: "Everything syncs through your own iCloud. No servers, no accounts.")
            }
            .padding(24)
        }
    }

    private var delivery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Do you have a Mac that can stay on?")
                    .font(.title.bold())
                Text("Apple doesn't let iPhone apps send messages by themselves. A Mac running BlueNudge Relay can, fully unattended. Without one, your iPhone reminds you and the message is one tap away.")
                    .foregroundStyle(.secondary)
                ChoiceCard(
                    title: "Yes, I have a Mac",
                    detail: "New reminders send automatically through the Mac relay.",
                    symbol: "desktopcomputer",
                    isSelected: hasMac == true
                ) { hasMac = true }
                ChoiceCard(
                    title: "No, iPhone only",
                    detail: "New reminders alert you with the message ready to send.",
                    symbol: "iphone",
                    isSelected: hasMac == false
                ) { hasMac = false }
                Text("You can change this per reminder at any time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var finish: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Almost done")
                    .font(.title.bold())
                Text("How should messages sign off? This fills {sender}.")
                    .foregroundStyle(.secondary)
                TextField("Your name or business", text: $senderName)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.name)
                Text("Next, allow notifications so tap-to-send reminders can alert you on time.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func advance() {
        if page < 2 {
            withAnimation { page += 1 }
        } else {
            complete()
        }
    }

    private func complete() {
        let repository = Repository(context: modelContext)
        let settings = repository.settings()
        if let hasMac {
            settings.defaultMethod = hasMac ? .relay : .tapToSend
        }
        let name = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            settings.senderName = name
        }
        settings.updatedAt = Date()
        repository.save()
        appState.completeOnboarding()
        Task {
            await NotificationScheduler.requestAuthorization()
            appState.dataDidChange()
        }
    }
}

private struct FeatureLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            Text(text)
        }
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

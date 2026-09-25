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
        case "editor":
            appState.selectedTab = .reminders
            // Let the tab settle before presenting over it.
            try? await Task.sleep(nanoseconds: 600_000_000)
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

/// First run: what the app does, whether there's a Mac to send texts, and
/// where the texts should go.
struct OnboardingView: View {
    @ObservedObject private var appState = AppState.shared
    @Environment(\.modelContext) private var modelContext

    private enum Page: Int {
        case welcome, delivery, number
    }

    @State private var page: Page = .welcome
    @State private var hasMac: Bool?
    @State private var handle = ""

    private var repository: Repository { Repository(context: modelContext) }

    private var normalizedHandle: String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let code = repository.existingSettings()?.defaultCountryCode
            ?? CallingCodes.callingCode(forRegion: Locale.current.region?.identifier)
        return HandleNormalizer.normalize(trimmed, defaultCountryCode: code)
    }

    private var isLastPage: Bool {
        page == .number || (page == .delivery && hasMac == false)
    }

    private var canContinue: Bool {
        switch page {
        case .welcome: return true
        case .delivery: return hasMac != nil
        case .number: return normalizedHandle != nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView {
                    Group {
                        switch page {
                        case .welcome: welcome
                        case .delivery: delivery
                        case .number: number
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }

                PageDots(count: hasMac == false ? 2 : 3, current: page.rawValue)

                Button(action: advance) {
                    Text(isLastPage ? "Get started" : "Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinue)
                .padding(.horizontal, 24)
            }
            .padding(.bottom)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if page != .welcome {
                        Button("Back") { withAnimation { goBack() } }
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
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Reminders that arrive as texts")
                .font(.largeTitle.bold())
            Text("BlueNudge texts your reminders to you in Messages, where they're hard to miss and easy to find later.")
                .foregroundStyle(.secondary)
            FeatureLine(symbol: "calendar.badge.clock", text: "Once, hourly, daily, weekly, monthly or yearly, with quiet hours for hourly ones.")
            FeatureLine(symbol: "arrowshape.turn.up.left.fill", text: "Reply SNOOZE to get it again in 10 minutes, or SNOOZE 1H. Reply STOP to pause everything.")
            FeatureLine(symbol: "icloud.fill", text: "Private: reminders sync through your own iCloud. No accounts, no servers.")
            FeatureLine(symbol: "dollarsign.circle.fill", text: "No per-text fees. Texts go out through Messages on your Mac.")
        }
    }

    private var delivery: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Do you have a Mac that can stay on?")
                .font(.title.bold())
            Text("iPhone apps can't send texts on their own. A Mac running BlueNudge Relay can, so your reminders arrive as real texts. Without a Mac, you get a notification instead.")
                .foregroundStyle(.secondary)
            ChoiceCard(
                title: "Yes, text me",
                detail: "Reminders arrive in Messages, sent by the Mac.",
                symbol: "message.fill",
                isSelected: hasMac == true
            ) { hasMac = true }
            ChoiceCard(
                title: "No, notify me",
                detail: "Reminders arrive as notifications on this iPhone.",
                symbol: "bell.fill",
                isSelected: hasMac == false
            ) { hasMac = false }
            Text("You can change this for each reminder at any time.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var number: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Where should reminders be texted?")
                .font(.title.bold())
            Text("Your iPhone's number, or the email you use for iMessage.")
                .foregroundStyle(.secondary)
            TextField("Phone number or email", text: $handle)
                .textFieldStyle(.roundedBorder)
                .textContentType(.telephoneNumber)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let normalizedHandle {
                Label("Texts will go to \(HandleNormalizer.displayFormat(normalizedHandle))", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
            Label {
                Text("On the Mac, sign Messages in to a second Apple Account, not yours. Otherwise the texts look like you sent them and your iPhone won't alert you. Settings › Mac relay has the steps.")
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(Color.accentColor)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func advance() {
        if isLastPage {
            complete()
            return
        }
        withAnimation {
            switch page {
            case .welcome: page = .delivery
            case .delivery: page = .number
            case .number: break
            }
        }
    }

    private func goBack() {
        switch page {
        case .welcome: break
        case .delivery: page = .welcome
        case .number: page = .delivery
        }
    }

    private func complete() {
        let settings = repository.settings()
        if let hasMac {
            settings.defaultMethod = hasMac ? .relay : .notification
            settings.updatedAt = Date()
        }
        repository.save()
        if hasMac == true, normalizedHandle != nil {
            repository.setMyHandle(handle.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        appState.completeOnboarding()
        Task {
            await NotificationScheduler.requestAuthorization()
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

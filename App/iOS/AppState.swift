import SwiftUI
import SwiftData
import CoreData
import Combine
import ReminderCore

/// App-wide UI state: navigation requests from notifications and intents, and
/// keeping scheduled notifications in step with the data.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Tab: Hashable {
        case today, reminders, activity, settings
    }

    @Published var selectedTab: Tab = .today
    @Published var isShowingOnboarding = false
    @Published var iCloudAccount = "Checking…"
    /// Bumped whenever data changes elsewhere (e.g. iCloud import) so views re-plan.
    @Published var refreshToken = UUID()

    private var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    private var remoteChangeObserver: AnyCancellable?
    private var rescheduleTask: Task<Void, Never>?

    private init() {
        // CloudKit imports from other devices arrive as persistent-store remote
        // change notifications; refresh the plan and notifications when they do.
        remoteChangeObserver = NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.dataDidChange()
            }
    }

    var repository: Repository { Repository(context: DataStore.shared.mainContext) }

    func appDidBecomeActive() async {
        if !hasCompletedOnboarding && !DemoMode.isEnabled {
            isShowingOnboarding = true
        }
        let settings = repository.settings()
        repository.pruneDeliveries(olderThanDays: settings.logRetentionDays)
        repository.pruneFinishedSnoozes()
        await NotificationScheduler.reschedule(using: repository)
        iCloudAccount = await DataStore.shared.iCloudAccountDescription()
        refreshToken = UUID()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        isShowingOnboarding = false
    }

    /// Call after local edits; debounced so a burst of saves reschedules once.
    func dataDidChange() {
        refreshToken = UUID()
        rescheduleTask?.cancel()
        rescheduleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            await NotificationScheduler.reschedule(using: self.repository)
        }
    }
}

/// Automatic texts that should have gone out but have no delivery record yet,
/// usually because the relay Mac is off, asleep or signed out of iCloud.
@MainActor
enum LateTexts {
    static let lateAfter: TimeInterval = 10 * 60

    static func messages(repository: Repository, now: Date = Date()) -> [PlannedMessage] {
        let plan = repository.plan(method: .relay, lookback: 24 * 3_600, grace: 24 * 3_600, now: now)
        return plan.toSend.filter { $0.occurrence < now.addingTimeInterval(-lateAfter) }
    }
}

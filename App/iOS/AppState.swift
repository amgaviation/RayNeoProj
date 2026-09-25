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
        case today, reminders, people, activity, settings
    }

    @Published var selectedTab: Tab = .today
    @Published var isShowingSendQueue = false
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
        if !hasCompletedOnboarding {
            isShowingOnboarding = true
        }
        repository.settings()
        repository.pruneDeliveries(olderThanDays: repository.settings().logRetentionDays)
        await NotificationScheduler.reschedule(using: repository)
        iCloudAccount = await DataStore.shared.iCloudAccountDescription()
        refreshToken = UUID()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        isShowingOnboarding = false
    }

    func presentSendQueue() {
        selectedTab = .today
        isShowingSendQueue = true
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

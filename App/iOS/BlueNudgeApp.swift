import SwiftUI
import SwiftData
import UserNotifications

@main
struct BlueNudgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
        .modelContainer(DataStore.shared.container)
    }
}

/// Handles notification presentation and taps, and keeps iCloud push delivery on.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        SyncMonitor.shared.start()
        UNUserNotificationCenter.current().delegate = self
        NotificationScheduler.registerCategories()
        BackgroundRefresh.register()
        BackgroundRefresh.schedule()
        Task { @MainActor in
            SubscriptionStore.shared.start()
            await SubscriptionStore.shared.claimCurrentEntitlements()
            await TextingAccount.shared.refresh()
        }
        // SwiftData's CloudKit sync relies on silent pushes to pick up changes
        // made on other devices while this app is in the background.
        application.registerForRemoteNotifications()
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case NotificationScheduler.snoozeAction:
                await NotificationScheduler.snooze(content: content, minutes: 10)
            case UNNotificationDismissActionIdentifier:
                break
            default:
                AppState.shared.selectedTab = .today
            }
            completionHandler()
        }
    }
}

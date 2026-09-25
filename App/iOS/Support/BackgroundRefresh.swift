import BackgroundTasks
import Foundation

/// Tops up the server's queue of texts (and the local alarms and notifications)
/// every half day or so, even if the app isn't opened.
enum BackgroundRefresh {
    static let identifier = "com.amgaviationgroup.bluenudge.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            schedule()
            let work = Task { @MainActor in
                await AppState.shared.refreshScheduledDeliveries()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(12 * 3_600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

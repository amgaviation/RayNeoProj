import CoreData
import Foundation

/// Watches iCloud sync activity so both apps can show when data last synced and
/// why it failed. SwiftData syncs through NSPersistentCloudKitContainer, which
/// reports each setup, import and export as an event.
@MainActor
final class SyncMonitor: ObservableObject {
    static let shared = SyncMonitor()

    /// True once any sync event has been seen, i.e. iCloud sync is running.
    @Published private(set) var hasActivity = false
    @Published private(set) var lastImport: Date?
    @Published private(set) var lastExport: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorDate: Date?

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let key = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            guard let event = notification.userInfo?[key] as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated {
                self?.record(event)
            }
        }
    }

    /// Call once at launch so no early events are missed.
    func start() {}

    /// Demo mode: look like a healthy, recently synced setup.
    func applyDemoState() {
        hasActivity = true
        lastImport = Date().addingTimeInterval(-95)
        lastExport = Date().addingTimeInterval(-60)
        lastError = nil
    }

    private func record(_ event: NSPersistentCloudKitContainer.Event) {
        hasActivity = true
        guard let end = event.endDate else { return }  // still running
        if event.succeeded {
            switch event.type {
            case .import: lastImport = end
            case .export: lastExport = end
            case .setup: break
            @unknown default: break
            }
            if let lastErrorDate, end > lastErrorDate {
                lastError = nil
            }
        } else if let error = event.error {
            lastError = Self.describe(error)
            lastErrorDate = end
        }
    }

    /// Most recent successful sync in either direction.
    var lastSync: Date? {
        switch (lastImport, lastExport) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// One line for status screens.
    var summary: String {
        if let lastError { return "Sync problem: \(lastError)" }
        if let lastSync { return "Last synced \(lastSync.formatted(.relative(presentation: .named)))" }
        return hasActivity ? "Syncing…" : "Waiting for iCloud"
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        // CKError codes, without importing CloudKit here.
        switch (nsError.domain, nsError.code) {
        case ("CKErrorDomain", 9), (NSCocoaErrorDomain, 134400):
            return "Not signed in to iCloud on this device."
        case ("CKErrorDomain", 25):
            return "iCloud storage is full."
        case ("CKErrorDomain", 3), ("CKErrorDomain", 4):
            return "No internet connection."
        case ("CKErrorDomain", 5), ("CKErrorDomain", 8):
            return "The iCloud container isn't set up for this app. Check Signing & Capabilities › iCloud in both targets."
        case ("CKErrorDomain", 7):
            return "iCloud is rate-limiting requests; it will retry."
        default:
            return nsError.localizedDescription
        }
    }
}

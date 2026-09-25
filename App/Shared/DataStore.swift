import Foundation
import SwiftData
import CloudKit

/// Owns the one `ModelContainer` for the app.
///
/// Syncs through iCloud when the build carries the iCloud (CloudKit) entitlement,
/// which needs a paid Apple Developer account; without it SwiftData quietly stays
/// on-device. If the store cannot open at all it falls back to memory instead of
/// crashing, and `syncStatus` says why.
@MainActor
final class DataStore {
    static let shared = DataStore()

    enum SyncStatus: Equatable {
        /// Syncing through this CloudKit container.
        case iCloud(containerID: String)
        /// On-device only.
        case localOnly
        /// Nothing could be opened on disk; data lives in memory for this session.
        case temporary(String)

        var summary: String {
            switch self {
            case .iCloud: return "iCloud sync on"
            case .localOnly: return "On this device only"
            case .temporary: return "Temporary storage"
            }
        }

        var detail: String {
            switch self {
            case .iCloud(let id):
                return "Reminders, people and the delivery log sync through your iCloud account (\(id)). The iPhone app and the Mac relay must be signed in to the same Apple Account."
            case .localOnly:
                return "This build has no iCloud capability, so data stays on this device and the Mac relay cannot see it. Tap-to-send still works."
            case .temporary(let reason):
                return "Storage could not open, so changes will be lost when the app quits. \(reason)"
            }
        }
    }

    let container: ModelContainer
    let syncStatus: SyncStatus

    private init() {
        let schema = Schema(AppSchema.models)
        if DemoMode.isEnabled {
            // Sample data in memory only; real data is never opened.
            container = Self.inMemoryContainer(schema: schema)
            syncStatus = .iCloud(containerID: "iCloud.com.amgaviationgroup.bluenudge")
            DemoData.seed(into: container.mainContext)
            SyncMonitor.shared.applyDemoState()
            return
        }
        let url = Self.storeURL()
        do {
            // `.automatic` uses the first CloudKit container in the entitlements,
            // or none when the build has no iCloud capability.
            let configuration = ModelConfiguration(
                "BlueNudge",
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: .automatic
            )
            container = try ModelContainer(for: schema, migrationPlan: nil, configurations: [configuration])
            if let id = configuration.cloudKitContainerIdentifier, !id.isEmpty {
                syncStatus = .iCloud(containerID: id)
            } else {
                syncStatus = .localOnly
            }
        } catch {
            NSLog("BlueNudge: store failed to open: \(error)")
            do {
                let local = ModelConfiguration(
                    "BlueNudge",
                    schema: schema,
                    url: url,
                    allowsSave: true,
                    cloudKitDatabase: .none
                )
                container = try ModelContainer(for: schema, migrationPlan: nil, configurations: [local])
                syncStatus = .localOnly
            } catch {
                container = Self.inMemoryContainer(schema: schema)
                syncStatus = .temporary(error.localizedDescription)
            }
        }
    }

    var mainContext: ModelContext { container.mainContext }

    var cloudKitContainerID: String? {
        if case .iCloud(let id) = syncStatus { return id }
        return nil
    }

    /// True when iCloud sync is running, judged by the configuration or, as a
    /// fallback, by sync activity actually being reported.
    var isSyncConfigured: Bool {
        cloudKitContainerID != nil || SyncMonitor.shared.hasActivity
    }

    var syncSummary: String {
        if case .temporary = syncStatus { return syncStatus.summary }
        return isSyncConfigured ? SyncStatus.iCloud(containerID: "").summary : syncStatus.summary
    }

    var syncDetail: String {
        if case .temporary = syncStatus { return syncStatus.detail }
        if isSyncConfigured {
            return SyncStatus.iCloud(containerID: cloudKitContainerID ?? "the app's iCloud container").detail
        }
        return syncStatus.detail
    }

    private static func inMemoryContainer(schema: Schema) -> ModelContainer {
        let configuration = ModelConfiguration(
            "BlueNudgeTemporary",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, migrationPlan: nil, configurations: [configuration])
        } catch {
            fatalError("BlueNudge could not create even an in-memory store: \(error)")
        }
    }

    /// Application Support/<bundle id>/BlueNudge.store. The Mac relay is not
    /// sandboxed, so it needs its own folder rather than SwiftData's default path.
    private static func storeURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folder = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "BlueNudge", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("BlueNudge.store")
    }

    /// Human-readable iCloud account state for status screens. Only touches
    /// CloudKit when the build is entitled, since CloudKit traps otherwise.
    func iCloudAccountDescription() async -> String {
        if DemoMode.isEnabled { return "Signed in" }
        let container: CKContainer
        if let id = cloudKitContainerID {
            container = CKContainer(identifier: id)
        } else if SyncMonitor.shared.hasActivity {
            container = CKContainer.default()
        } else {
            return "Not used by this build"
        }
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available: return "Signed in"
            case .noAccount: return "Not signed in to iCloud"
            case .restricted: return "Restricted on this device"
            case .couldNotDetermine: return "Could not determine"
            case .temporarilyUnavailable: return "Temporarily unavailable"
            @unknown default: return "Unknown"
            }
        } catch {
            return "Unavailable: \(error.localizedDescription)"
        }
    }
}

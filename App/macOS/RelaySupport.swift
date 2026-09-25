import AppKit
import Foundation
import ServiceManagement
import SwiftUI

/// Settings that belong to this Mac only (the shared ones live in `SharedSettings`).
@MainActor
final class RelayPreferences: ObservableObject {
    static let shared = RelayPreferences()

    private let defaults = UserDefaults.standard

    /// Stable identity for this relay, used in heartbeats and relay election.
    let deviceID: String

    @Published var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Keys.paused) }
    }

    @Published var keepAwake: Bool {
        didSet {
            defaults.set(keepAwake, forKey: Keys.keepAwake)
            ActivityGuard.shared.update(keepAwake: keepAwake)
        }
    }

    @Published var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: Keys.setupDone) }
    }

    private enum Keys {
        static let deviceID = "relay.deviceID"
        static let paused = "relay.paused"
        static let keepAwake = "relay.keepAwake"
        static let setupDone = "relay.setupDone"
        static let lastScan = "relay.lastScan"
        static let lastInboundRowID = "relay.lastInboundRowID"
        static let recentSends = "relay.recentSends"
    }

    private init() {
        let store = UserDefaults.standard
        if let existing = store.string(forKey: Keys.deviceID) {
            deviceID = existing
        } else {
            let created = UUID().uuidString
            store.set(created, forKey: Keys.deviceID)
            deviceID = created
        }
        isPaused = store.bool(forKey: Keys.paused)
        keepAwake = store.object(forKey: Keys.keepAwake) as? Bool ?? true
        hasCompletedSetup = store.bool(forKey: Keys.setupDone)
    }

    /// When the relay last finished a pass.
    var lastScan: Date? {
        get { defaults.object(forKey: Keys.lastScan) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastScan) }
    }

    /// Newest incoming Messages row already checked for STOP replies.
    var lastInboundRowID: Int64? {
        get { (defaults.object(forKey: Keys.lastInboundRowID) as? NSNumber)?.int64Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: Keys.lastInboundRowID) }
    }

    /// Send times from the last 24 hours, for throttling and the status line.
    var recentSends: [Date] {
        get {
            let stamps = defaults.array(forKey: Keys.recentSends) as? [Double] ?? []
            return stamps.map { Date(timeIntervalSince1970: $0) }
        }
        set {
            let cutoff = Date().addingTimeInterval(-86_400)
            let kept = newValue.filter { $0 > cutoff }.map(\.timeIntervalSince1970)
            defaults.set(kept, forKey: Keys.recentSends)
        }
    }
}

/// Keeps App Nap from delaying the relay's timer and, optionally, the Mac from
/// idle-sleeping. A closed laptop lid still sleeps the Mac.
@MainActor
final class ActivityGuard {
    static let shared = ActivityGuard()
    private var token: NSObjectProtocol?

    func update(keepAwake: Bool) {
        if let token {
            ProcessInfo.processInfo.endActivity(token)
        }
        let options: ProcessInfo.ActivityOptions = keepAwake
            ? [.userInitiated, .idleSystemSleepDisabled]
            : [.userInitiatedAllowingIdleSystemSleep]
        token = ProcessInfo.processInfo.beginActivity(
            options: options,
            reason: "BlueNudge Relay sends scheduled reminders"
        )
    }
}

/// Open-at-login through the system Login Items list.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum SystemSettingsLink {
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let automation = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    static let loginItems = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// The dashboard lives in a plain AppKit window so it opens only on request
/// (a SwiftUI Window scene would also open at every login).
@MainActor
final class DashboardWindow {
    static let shared = DashboardWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let root = DashboardView()
                .modelContainer(DataStore.shared.container)
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: controller)
            window.title = "BlueNudge Relay"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 780, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("BlueNudgeRelayDashboard")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

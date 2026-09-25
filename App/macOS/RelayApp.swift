import AppKit
import SwiftUI

@main
struct BlueNudgeRelayApp: App {
    @NSApplicationDelegateAdaptor(RelayAppDelegate.self) private var appDelegate
    @StateObject private var engine = RelayEngine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: engine.condition.symbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

final class RelayAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let folder = DemoMode.snapshotDirectory {
            Task { @MainActor in
                await DemoSnapshots.write(to: folder)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        #endif
        // iCloud (CloudKit) pushes tell SwiftData when the iPhone changed something.
        NSApplication.shared.registerForRemoteNotifications()
        Task { @MainActor in
            SyncMonitor.shared.start()
            ActivityGuard.shared.update(keepAwake: RelayPreferences.shared.keepAwake)
            RelayEngine.shared.start()
            if !RelayPreferences.shared.hasCompletedSetup {
                DashboardWindow.shared.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// The small panel under the menu bar icon.
struct MenuBarContent: View {
    @ObservedObject private var engine = RelayEngine.shared
    @ObservedObject private var prefs = RelayPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: engine.condition.symbolName)
                    .font(.title2)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BlueNudge Relay").font(.headline)
                    Text(engine.condition.title)
                        .font(.subheadline)
                        .foregroundStyle(tint)
                }
            }

            if engine.condition.needsAttention || engine.note != nil {
                Text(engine.note ?? engine.condition.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                StatLine(label: "Sent in last 24 h", value: "\(engine.sentLast24h)")
                StatLine(label: "Automatic reminders", value: "\(engine.automaticRemindersSeen)")
                if let next = engine.nextDue {
                    StatLine(label: "Next", value: "\(next.title) · \(next.date.formatted(date: .abbreviated, time: .shortened))")
                }
                if let lastCheck = engine.lastCheck {
                    StatLine(label: "Last check", value: lastCheck.formatted(date: .omitted, time: .standard))
                }
            }

            Divider()

            HStack {
                Button(prefs.isPaused ? "Resume" : "Pause") {
                    engine.setPaused(!prefs.isPaused)
                }
                Button("Check now") {
                    Task { await engine.tick(forceHeartbeat: true) }
                }
                .disabled(engine.isChecking)
                Spacer()
            }
            HStack {
                Button("Open dashboard…") {
                    DashboardWindow.shared.show()
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var tint: Color {
        switch engine.condition {
        case .running: return .green
        case .attention: return .red
        case .paused, .standby: return .orange
        case .starting: return .secondary
        }
    }
}

private struct StatLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.caption)
    }
}

import SwiftUI
import ReminderCore

/// Colored capsule for a delivery status.
struct StatusBadge: View {
    let status: DeliveryStatus

    var body: some View {
        Label(status.title, systemImage: status.symbolName)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(status.tint)
            .background(status.tint.opacity(0.14), in: Capsule())
    }
}

/// Small capsule showing how a reminder is delivered.
struct MethodBadge: View {
    let method: DeliveryMethod

    var body: some View {
        Label(method.shortTitle, systemImage: method.symbolName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(method.tint)
            .background(method.tint.opacity(0.12), in: Capsule())
    }
}

extension DeliveryStatus {
    var symbolName: String {
        switch self {
        case .sending: return "clock"
        case .sent: return "paperplane.fill"
        case .delivered: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .missed: return "clock.badge.exclamationmark"
        case .skipped: return "forward.fill"
        case .optedOut: return "pause.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .sending: return .gray
        case .sent: return .blue
        case .delivered: return .green
        case .failed: return .red
        case .missed: return .orange
        case .skipped: return .secondary
        case .optedOut: return .purple
        }
    }
}

extension DeliveryMethod {
    var symbolName: String {
        switch self {
        case .sms: return "message.fill"
        case .alarm: return "alarm.fill"
        case .notification: return "bell.fill"
        case .relay: return "laptopcomputer"
        }
    }

    var tint: Color {
        switch self {
        case .sms: return .green
        case .alarm: return .red
        case .notification: return .orange
        case .relay: return .accentColor
        }
    }

    /// Methods to offer in pickers on this device. "Text from my Mac" only shows
    /// once a relay Mac has checked in, or when it's already in use.
    @MainActor
    static func available(hasRelay: Bool, including current: DeliveryMethod? = nil) -> [DeliveryMethod] {
        allCases.filter { method in
            if method == current { return true }
            switch method {
            case .sms: return TextingAccount.shared.isConfigured
            case .alarm: return AlarmScheduler.isSupported
            case .notification: return true
            case .relay: return hasRelay
            }
        }
    }
}

/// Relay online/offline summary shared by Today and Settings.
struct RelayStatusView: View {
    let heartbeat: RelayHeartbeat?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var isOnline: Bool { heartbeat?.isOnline() ?? false }

    private var symbol: String {
        guard let heartbeat else { return "desktopcomputer.trianglebadge.exclamationmark" }
        if heartbeat.isPaused { return "pause.circle.fill" }
        if !isOnline { return "moon.zzz.fill" }
        return heartbeat.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var tint: Color {
        guard let heartbeat else { return .secondary }
        if heartbeat.isPaused || !isOnline { return .orange }
        return heartbeat.needsAttention ? .red : .green
    }

    private var title: String {
        guard let heartbeat else { return "No Mac relay yet" }
        if heartbeat.isPaused { return "Relay paused on \(heartbeat.deviceName)" }
        if !isOnline { return "Relay offline: \(heartbeat.deviceName)" }
        return "Relay online: \(heartbeat.deviceName)"
    }

    private var detail: String {
        guard let heartbeat else {
            return "Text reminders are sent by BlueNudge Relay on a Mac. Notification-only reminders work without it."
        }
        let seen = "Last check-in \(heartbeat.lastSeen.formatted(.relative(presentation: .named)))"
        if !heartbeat.statusText.isEmpty {
            return "\(heartbeat.statusText) · \(seen)"
        }
        return "\(heartbeat.sentLast24h) sent in the last 24 h · \(seen)"
    }
}

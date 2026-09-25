import Foundation
import ReminderCore

/// What the iPhone should offer to send right now.
@MainActor
enum SendQueue {
    /// Tap-to-send messages stay in the queue this long before they drop off.
    static let lookback: TimeInterval = 48 * 3_600
    /// A relay message counts as overdue once it is this late with no record.
    static let relayOverdueAfter: TimeInterval = 10 * 60

    static func dueMessages(repository: Repository, now: Date = Date()) -> [PlannedMessage] {
        repository.plan(method: .tapToSend, lookback: lookback, grace: lookback, now: now).toSend
    }

    /// Relay messages that should have gone out but have no delivery record yet,
    /// usually because the Mac is off, asleep or signed out of iCloud.
    static func overdueRelayMessages(repository: Repository, now: Date = Date()) -> [PlannedMessage] {
        let plan = repository.plan(method: .relay, lookback: 24 * 3_600, grace: 24 * 3_600, now: now)
        let cutoff = now.addingTimeInterval(-relayOverdueAfter)
        return plan.toSend.filter { $0.occurrence < cutoff }
    }

    /// Records a message handled on this iPhone and refreshes badges/notifications.
    static func record(
        _ message: PlannedMessage,
        status: DeliveryStatus,
        channel: DeliveryChannel = .iPhone,
        note: String = "",
        repository: Repository
    ) {
        repository.record(message, status: status, channel: channel, deviceName: DeviceInfo.name, error: note)
        repository.save()
        AppState.shared.dataDidChange()
    }
}

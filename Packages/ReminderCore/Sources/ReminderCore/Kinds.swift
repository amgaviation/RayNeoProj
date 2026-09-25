import Foundation

/// How a reminder reaches you.
public enum DeliveryMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Texted to your phone as an iMessage by BlueNudge Relay running on a Mac.
    case relay
    /// A notification on the iPhone itself. Works without a Mac.
    case notification

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .relay: return "Text me"
        case .notification: return "Notification only"
        }
    }

    public var shortTitle: String {
        switch self {
        case .relay: return "Text"
        case .notification: return "Notification"
        }
    }

    public var explanation: String {
        switch self {
        case .relay:
            return "Arrives in Messages as a text, sent by BlueNudge Relay on your Mac. Free, but the Mac has to stay on."
        case .notification:
            return "A regular notification on this iPhone. Free, no Mac needed, but it isn't a text."
        }
    }
}

/// What happened to one message (one recipient × one occurrence).
public enum DeliveryStatus: String, Codable, CaseIterable, Sendable {
    /// Handed to Messages; the outcome could not be confirmed yet.
    case sending
    /// Messages accepted it.
    case sent
    /// A delivery receipt was seen in the Messages database.
    case delivered
    /// Messages reported an error.
    case failed
    /// Not sent because it was already later than the grace window allows.
    case missed
    /// Deliberately skipped by the user.
    case skipped
    /// Not sent because texts were paused (a STOP reply or the Pause switch).
    case optedOut

    public var title: String {
        switch self {
        case .sending: return "Sending"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .failed: return "Failed"
        case .missed: return "Missed"
        case .skipped: return "Skipped"
        case .optedOut: return "Paused"
        }
    }

    /// True when the message left the device (or at least was handed to Messages).
    public var countsAsSent: Bool {
        switch self {
        case .sending, .sent, .delivered: return true
        default: return false
        }
    }
}

/// Which path produced a delivery record.
public enum DeliveryChannel: String, Codable, CaseIterable, Sendable {
    case relay
    case iPhone
    case shortcut

    public var title: String {
        switch self {
        case .relay: return "Mac relay"
        case .iPhone: return "iPhone"
        case .shortcut: return "Shortcuts"
        }
    }
}

/// Which Messages service the relay should use for a recipient.
public enum MessageService: String, Codable, CaseIterable, Identifiable, Sendable {
    /// iMessage first; SMS through the paired iPhone only if SMS fallback is enabled.
    case auto
    case iMessage
    /// Plain SMS relayed through the paired iPhone (Text Message Forwarding).
    case sms

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Automatic"
        case .iMessage: return "iMessage only"
        case .sms: return "SMS (via iPhone)"
        }
    }
}

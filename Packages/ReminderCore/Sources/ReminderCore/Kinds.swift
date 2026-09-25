import Foundation

/// How a reminder gets delivered.
public enum DeliveryMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A Mac running BlueNudge Relay sends it through Messages, unattended.
    case relay
    /// The iPhone alerts you and you tap Send (or a Shortcuts automation sends it).
    case tapToSend

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .relay: return "Automatic (Mac relay)"
        case .tapToSend: return "Tap to send (iPhone)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .relay: return "Automatic"
        case .tapToSend: return "Tap to send"
        }
    }

    public var explanation: String {
        switch self {
        case .relay:
            return "Sent unattended by the Mac relay through Messages. Free, but needs a Mac that stays on."
        case .tapToSend:
            return "Your iPhone alerts you at the scheduled time and opens a ready-to-send message. Free, no Mac needed."
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
    /// Not sent because the recipient opted out.
    case optedOut

    public var title: String {
        switch self {
        case .sending: return "Sending"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .failed: return "Failed"
        case .missed: return "Missed"
        case .skipped: return "Skipped"
        case .optedOut: return "Opted out"
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

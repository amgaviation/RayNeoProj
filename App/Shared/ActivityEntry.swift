import Foundation
import ReminderCore

/// One line in Activity: a text from the Mac relay (a DeliveryRecord synced
/// through iCloud) or one sent by BlueNudge's texting server.
struct ActivityEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let text: String
    let due: Date
    /// When it happened, for sorting and grouping by day.
    let date: Date
    let sentAt: Date?
    let deliveredAt: Date?
    let status: DeliveryStatus
    /// How it was sent, e.g. "iMessage · Home Mac mini" or "Text message".
    let via: String
    let note: String

    init(record: DeliveryRecord) {
        id = "record-\(record.id.uuidString)"
        title = record.reminderTitle.isEmpty ? "Reminder" : record.reminderTitle
        text = record.messageText
        due = record.occurrenceDate
        date = record.createdAt
        sentAt = record.sentAt
        deliveredAt = record.deliveredAt
        status = record.status
        var via = [record.serviceUsed.isEmpty ? record.channel.title : record.serviceUsed]
        if !record.deviceName.isEmpty, record.channel == .relay {
            via.append(record.deviceName)
        }
        self.via = via.joined(separator: " · ")
        note = record.errorMessage
    }

    init(text: RemoteText) {
        id = "text-\(text.id)"
        title = text.title.isEmpty ? "Reminder" : text.title
        self.text = text.body
        due = text.fireAt
        date = text.sentAt ?? text.fireAt
        sentAt = text.sentAt
        deliveredAt = text.status == "delivered" ? text.sentAt : nil
        status = Self.status(server: text.status, error: text.error)
        via = "Text message"
        note = text.error ?? ""
    }

    /// The server's outbox status as a delivery status.
    static func status(server: String, error: String?) -> DeliveryStatus {
        switch server {
        case "pending", "sending": return .sending
        case "sent": return .sent
        case "delivered": return .delivered
        case "failed": return .failed
        case "missed": return .missed
        case "skipped":
            return error?.localizedCaseInsensitiveContains("paused") == true ? .optedOut : .skipped
        default: return .sent
        }
    }

    /// Mac texts and server texts together, newest first.
    static func merged(records: [DeliveryRecord], texts: [RemoteText]) -> [ActivityEntry] {
        (records.map(ActivityEntry.init(record:)) + texts.map(ActivityEntry.init(text:)))
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ReminderCore

/// Every reminder texted to you: sent, delivered, failed, missed…
struct ActivityView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, sent, problems
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .sent: return "Sent"
            case .problems: return "Problems"
            }
        }
    }

    @Query(sort: \DeliveryRecord.createdAt, order: .reverse) private var records: [DeliveryRecord]
    @State private var filter: Filter = .all
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            let shown = records.filter(include)
            List {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if shown.isEmpty {
                    ContentUnavailableView(
                        "Nothing here yet",
                        systemImage: "tray",
                        description: Text("Every reminder texted to you, and any that were missed or failed, shows up here.")
                    )
                } else {
                    ForEach(groupedByDay(shown), id: \.day) { group in
                        Section(group.day.formatted(date: .complete, time: .omitted)) {
                            ForEach(group.records) { record in
                                DeliveryRow(record: record)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search reminders")
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(
                        item: DeliveryLogExport(records: shown.map(DeliveryLogExport.Row.init)),
                        preview: SharePreview("BlueNudge history")
                    ) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(shown.isEmpty)
                }
            }
        }
    }

    private func include(_ record: DeliveryRecord) -> Bool {
        switch filter {
        case .all: break
        case .sent: guard record.status.countsAsSent else { return false }
        case .problems: guard [.failed, .missed].contains(record.status) else { return false }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return record.reminderTitle.localizedCaseInsensitiveContains(query)
            || record.messageText.localizedCaseInsensitiveContains(query)
    }

    private struct DayGroup {
        let day: Date
        let records: [DeliveryRecord]
    }

    private func groupedByDay(_ records: [DeliveryRecord]) -> [DayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [DeliveryRecord]] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.createdAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(record)
        }
        return order.map { DayGroup(day: $0, records: buckets[$0] ?? []) }
    }
}

struct DeliveryRow: View {
    let record: DeliveryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.reminderTitle.isEmpty ? "Reminder" : record.reminderTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                StatusBadge(status: record.status)
            }
            Text(record.messageText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(detailLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if !record.errorMessage.isEmpty {
                Text(record.errorMessage)
                    .font(.caption2)
                    .foregroundStyle(record.status == .failed ? Color.red : Color.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var detailLine: String {
        var parts: [String] = []
        parts.append("due \(record.occurrenceDate.formatted(date: .abbreviated, time: .shortened))")
        if let delivered = record.deliveredAt {
            parts.append("delivered \(delivered.formatted(date: .omitted, time: .shortened))")
        } else if let sent = record.sentAt {
            parts.append("sent \(sent.formatted(date: .omitted, time: .shortened))")
        }
        var via = record.channel.title
        if !record.serviceUsed.isEmpty { via += " · \(record.serviceUsed)" }
        if !record.deviceName.isEmpty, record.channel == .relay { via += " (\(record.deviceName))" }
        parts.append(via)
        return parts.joined(separator: " · ")
    }
}

/// The log as a CSV file for the share sheet. Built only when shared.
struct DeliveryLogExport: Transferable {
    struct Row {
        let values: [String]

        init(_ record: DeliveryRecord) {
            let iso = ISO8601DateFormatter()
            values = [
                iso.string(from: record.occurrenceDate),
                record.sentAt.map { iso.string(from: $0) } ?? "",
                record.deliveredAt.map { iso.string(from: $0) } ?? "",
                record.status.title,
                record.channel.title,
                record.serviceUsed,
                record.reminderTitle,
                record.recipientName,
                record.recipientHandle,
                record.messageText,
                record.errorMessage,
                record.deviceName,
            ]
        }
    }

    static let header = [
        "Due", "Sent", "Delivered", "Status", "Channel", "Service", "Reminder",
        "Recipient", "Handle", "Message", "Note", "Device",
    ]

    let records: [Row]

    var csv: String {
        CSV.make(header: Self.header, rows: records.map(\.values))
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { export in
            Data(export.csv.utf8)
        }
        .suggestedFileName("BlueNudge-delivery-log.csv")
    }
}

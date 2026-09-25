import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ReminderCore

/// Every reminder texted to you, from BlueNudge's server or the Mac relay:
/// sent, delivered, failed, missed…
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
    @ObservedObject private var texting = TextingAccount.shared
    @State private var filter: Filter = .all
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            let shown = ActivityEntry.merged(records: records, texts: texting.recentTexts).filter(include)
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
                            ForEach(group.entries) { entry in
                                DeliveryRow(entry: entry)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search reminders")
            .refreshable { await texting.refresh() }
            .task { await texting.refresh() }
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

    private func include(_ entry: ActivityEntry) -> Bool {
        switch filter {
        case .all: break
        case .sent: guard entry.status.countsAsSent else { return false }
        case .problems: guard [.failed, .missed, .skipped].contains(entry.status) else { return false }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return entry.title.localizedCaseInsensitiveContains(query)
            || entry.text.localizedCaseInsensitiveContains(query)
    }

    private struct DayGroup {
        let day: Date
        let entries: [ActivityEntry]
    }

    private func groupedByDay(_ entries: [ActivityEntry]) -> [DayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [ActivityEntry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }
        return order.map { DayGroup(day: $0, entries: buckets[$0] ?? []) }
    }
}

struct DeliveryRow: View {
    let entry: ActivityEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                StatusBadge(status: entry.status)
            }
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(detailLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(.caption2)
                    .foregroundStyle(entry.status == .failed ? Color.red : Color.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var detailLine: String {
        var parts = ["Due \(entry.due.formatted(date: .omitted, time: .shortened))"]
        // Only worth saying when it went out noticeably late.
        if let sent = entry.sentAt, sent.timeIntervalSince(entry.due) > 120 {
            parts.append("sent \(sent.formatted(date: .omitted, time: .shortened))")
        }
        parts.append(entry.via)
        return parts.joined(separator: " · ")
    }
}

/// The log as a CSV file for the share sheet. Built only when shared.
struct DeliveryLogExport: Transferable {
    struct Row {
        let values: [String]

        init(_ entry: ActivityEntry) {
            let iso = ISO8601DateFormatter()
            values = [
                iso.string(from: entry.due),
                entry.sentAt.map { iso.string(from: $0) } ?? "",
                entry.deliveredAt.map { iso.string(from: $0) } ?? "",
                entry.status.title,
                entry.via,
                entry.title,
                entry.text,
                entry.note,
            ]
        }
    }

    static let header = ["Due", "Sent", "Delivered", "Status", "Via", "Reminder", "Message", "Note"]

    let records: [Row]

    var csv: String {
        CSV.make(header: Self.header, rows: records.map(\.values))
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { export in
            Data(export.csv.utf8)
        }
        .suggestedFileName("BlueNudge-activity.csv")
    }
}

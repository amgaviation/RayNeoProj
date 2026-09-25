import SwiftUI
import SwiftData
import ReminderCore

// MARK: - People tab

struct PeopleListView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var appState = AppState.shared

    @Query(sort: \Recipient.name) private var recipients: [Recipient]
    @Query private var reminders: [Reminder]

    @State private var searchText = ""
    @State private var isAdding = false
    @State private var editing: Recipient?

    private var repository: Repository { Repository(context: modelContext) }

    var body: some View {
        NavigationStack {
            let filtered = recipients.filter { RecipientSearch.matches($0, searchText) }
            List {
                if recipients.isEmpty {
                    ContentUnavailableView {
                        Label("No people yet", systemImage: "person.2")
                    } description: {
                        Text("Add the people you send reminders to, or import them from Contacts.")
                    } actions: {
                        Button("Import from Contacts") { importContacts() }
                            .buttonStyle(.borderedProminent)
                        Button("Add manually") { isAdding = true }
                    }
                }
                ForEach(filtered) { recipient in
                    Button {
                        editing = recipient
                    } label: {
                        RecipientRow(recipient: recipient, reminderCount: reminderCount(for: recipient))
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            repository.delete(recipient)
                            appState.dataDidChange()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search people")
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add manually", systemImage: "person.badge.plus") { isAdding = true }
                        Button("Import from Contacts", systemImage: "person.crop.circle.badge.plus") { importContacts() }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAdding) {
                RecipientEditorView(recipient: nil)
            }
            .sheet(item: $editing) { recipient in
                RecipientEditorView(recipient: recipient)
            }
        }
    }

    private func reminderCount(for recipient: Recipient) -> Int {
        reminders.filter { $0.recipientIDs.contains(recipient.id) }.count
    }

    private func importContacts() {
        ContactImporter.shared.present { picked in
            RecipientFactory.upsert(picked, repository: repository)
            appState.dataDidChange()
        }
    }
}

struct RecipientRow: View {
    let recipient: Recipient
    var reminderCount: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(initials)
                .font(.subheadline.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipient.displayName)
                    .font(.body)
                Text(recipient.displayHandle)
                    .font(.caption)
                    .foregroundStyle(recipient.hasValidHandle ? Color.secondary : Color.red)
            }
            Spacer()
            if recipient.optedOut {
                Label("Opted out", systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
            } else if let reminderCount, reminderCount > 0 {
                Text(reminderCount == 1 ? "1 reminder" : "\(reminderCount) reminders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var initials: String {
        let letters = recipient.name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }
}

enum RecipientSearch {
    static func matches(_ recipient: Recipient, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return recipient.name.localizedCaseInsensitiveContains(query)
            || recipient.rawHandle.localizedCaseInsensitiveContains(query)
            || recipient.handle.localizedCaseInsensitiveContains(query)
    }
}

/// Creates recipients from picked contacts, reusing anyone already saved with
/// the same number or email.
@MainActor
enum RecipientFactory {
    @discardableResult
    static func upsert(_ picked: [ContactImporter.PickedContact], repository: Repository) -> [UUID] {
        let countryCode = repository.settings().defaultCountryCode
        let existing = repository.recipients()
        var ids: [UUID] = []
        for contact in picked {
            let normalized = HandleNormalizer.normalize(contact.handle, defaultCountryCode: countryCode) ?? ""
            if !normalized.isEmpty, let match = existing.first(where: { $0.handle == normalized }) {
                ids.append(match.id)
                continue
            }
            let recipient = Recipient(name: contact.name, rawHandle: contact.handle, handle: normalized)
            repository.context.insert(recipient)
            ids.append(recipient.id)
        }
        repository.save()
        return ids
    }
}

// MARK: - Picker used by the reminder editor

struct RecipientPickerView: View {
    @Binding var selection: [UUID]

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var appState = AppState.shared
    @Query(sort: \Recipient.name) private var recipients: [Recipient]

    @State private var searchText = ""
    @State private var isAdding = false

    private var repository: Repository { Repository(context: modelContext) }

    var body: some View {
        let filtered = recipients.filter { RecipientSearch.matches($0, searchText) }
        List {
            Section {
                Button {
                    isAdding = true
                } label: {
                    Label("New person", systemImage: "person.badge.plus")
                }
                Button {
                    ContactImporter.shared.present { picked in
                        let ids = RecipientFactory.upsert(picked, repository: repository)
                        for id in ids where !selection.contains(id) {
                            selection.append(id)
                        }
                        appState.dataDidChange()
                    }
                } label: {
                    Label("Import from Contacts", systemImage: "person.crop.circle.badge.plus")
                }
            }
            Section {
                ForEach(filtered) { recipient in
                    Button {
                        toggle(recipient.id)
                    } label: {
                        HStack {
                            RecipientRow(recipient: recipient)
                            Image(systemName: selection.contains(recipient.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selection.contains(recipient.id) ? Color.accentColor : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                if recipients.contains(where: \.optedOut) {
                    Text("People who opted out are skipped automatically, even if selected.")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search people")
        .navigationTitle("Recipients")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Select all shown") {
                        for recipient in filtered where !selection.contains(recipient.id) {
                            selection.append(recipient.id)
                        }
                    }
                    Button("Clear selection") { selection.removeAll() }
                } label: {
                    Image(systemName: "checklist")
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            RecipientEditorView(recipient: nil) { newID in
                if !selection.contains(newID) { selection.append(newID) }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if let index = selection.firstIndex(of: id) {
            selection.remove(at: index)
        } else {
            selection.append(id)
        }
    }
}

// MARK: - Add / edit a person

struct RecipientEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var appState = AppState.shared

    let recipient: Recipient?
    var onCreate: ((UUID) -> Void)? = nil

    @Query private var deliveries: [DeliveryRecord]

    @State private var name = ""
    @State private var rawHandle = ""
    @State private var notes = ""
    @State private var service: MessageService = .auto
    @State private var optedOut = false
    @State private var hasLoaded = false
    @State private var isConfirmingDelete = false

    init(recipient: Recipient?, onCreate: ((UUID) -> Void)? = nil) {
        self.recipient = recipient
        self.onCreate = onCreate
        _deliveries = Query(Repository.deliveriesDescriptor(recipientID: recipient?.id ?? UUID(), limit: 20))
    }

    private var repository: Repository { Repository(context: modelContext) }

    private var countryCode: String {
        repository.existingSettings()?.defaultCountryCode ?? "1"
    }

    private var normalized: String? {
        HandleNormalizer.normalize(rawHandle, defaultCountryCode: countryCode)
    }

    private var duplicate: Recipient? {
        guard let normalized else { return nil }
        return repository.recipients().first { $0.handle == normalized && $0.id != recipient?.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    TextField("Mobile number or iMessage email", text: $rawHandle)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.default)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if rawHandle.isEmpty {
                        Text("Numbers without a country code use +\(countryCode) (change it in Settings).")
                    } else if let normalized {
                        if let duplicate {
                            Text("\(duplicate.displayName) already uses \(HandleNormalizer.displayFormat(normalized)).")
                                .foregroundStyle(.orange)
                        } else {
                            Text("Messages will go to \(HandleNormalizer.displayFormat(normalized)).")
                        }
                    } else {
                        Text("That doesn't look like a phone number or email address.")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Send using", selection: $service) {
                        ForEach(MessageService.allCases) { service in
                            Text(service.title).tag(service)
                        }
                    }
                } footer: {
                    Text("Used by the Mac relay. SMS goes out through your iPhone's plan via Text Message Forwarding, so it also costs nothing extra on unlimited-text plans.")
                }

                Section {
                    Toggle("Opted out", isOn: $optedOut)
                } footer: {
                    Text("Opted-out people never receive reminders. The relay sets this automatically when someone replies STOP.")
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if recipient != nil, !deliveries.isEmpty {
                    Section("Recent messages") {
                        ForEach(deliveries) { record in
                            DeliveryRow(record: record, showRecipient: false)
                        }
                    }
                }

                if recipient != nil {
                    Section {
                        Button("Delete person", role: .destructive) { isConfirmingDelete = true }
                    }
                }
            }
            .navigationTitle(recipient == nil ? "New Person" : "Edit Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(normalized == nil)
                }
            }
            .onAppear(perform: load)
            .confirmationDialog("Delete this person?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let recipient {
                        repository.delete(recipient)
                        appState.dataDidChange()
                    }
                    dismiss()
                }
            } message: {
                Text("They are removed from every reminder. Their delivery history stays in Activity.")
            }
        }
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let recipient else { return }
        name = recipient.name
        rawHandle = recipient.rawHandle.isEmpty ? recipient.handle : recipient.rawHandle
        notes = recipient.notes
        service = recipient.service
        optedOut = recipient.optedOut
    }

    private func save() {
        let handle = normalized ?? ""
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let recipient {
            recipient.name = trimmedName
            recipient.rawHandle = rawHandle
            recipient.handle = handle
            recipient.notes = notes
            recipient.service = service
            if recipient.optedOut != optedOut {
                recipient.setOptedOut(optedOut, source: "manual")
            }
            recipient.updatedAt = Date()
        } else {
            let created = Recipient(name: trimmedName, rawHandle: rawHandle, handle: handle, notes: notes)
            created.service = service
            if optedOut { created.setOptedOut(true, source: "manual") }
            modelContext.insert(created)
            onCreate?(created.id)
        }
        repository.save()
        appState.dataDidChange()
        dismiss()
    }
}

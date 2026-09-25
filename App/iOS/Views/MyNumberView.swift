import SwiftUI
import SwiftData
import ReminderCore

/// Where reminder texts go: the phone number or iMessage email of this iPhone.
struct MyNumberView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var appState = AppState.shared

    @State private var kind: Kind = .phone
    @State private var handle = ""
    @State private var countryCode = "1"
    @State private var hasLoaded = false

    enum Kind: String, CaseIterable, Identifiable {
        case phone, email
        var id: String { rawValue }
        var title: String { self == .phone ? "Phone number" : "Email" }
    }

    private var repository: Repository { Repository(context: modelContext) }

    private var normalized: String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return HandleNormalizer.normalize(trimmed, defaultCountryCode: countryCode)
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if kind == .phone {
                    HStack {
                        Text("+").foregroundStyle(.secondary)
                        TextField("1", text: $countryCode)
                            .keyboardType(.numberPad)
                            .frame(width: 44)
                        Divider()
                        TextField("Phone number", text: $handle)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                    }
                } else {
                    TextField("you@icloud.com", text: $handle)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Text my reminders to")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let normalized {
                        Label("Texts will go to \(HandleNormalizer.displayFormat(normalized))", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if !handle.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label(kind == .phone ? "That doesn't look like a phone number." : "That doesn't look like an email address.", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text("Use a number or email this iPhone receives iMessages on. You can check in Settings › Apps › Messages › Send & Receive.")
                }
            }

            Section {
                Label {
                    Text("The Mac relay should text you from its own Apple Account, not yours. Texts from your own account look like you sent them, so your iPhone won't alert you.")
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.accentColor)
                }
                .font(.subheadline)
                NavigationLink("How to set up the Mac") { RelaySetupGuideView() }
            }
        }
        .navigationTitle("My Number")
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
        .onChange(of: countryCode) { _, newValue in
            let digits = newValue.filter(\.isNumber)
            if digits != newValue { countryCode = digits }
        }
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        countryCode = repository.existingSettings()?.defaultCountryCode
            ?? CallingCodes.callingCode(forRegion: Locale.current.region?.identifier)
        if let me = repository.me() {
            handle = me.rawHandle.isEmpty ? me.displayHandle : me.rawHandle
            kind = HandleNormalizer.isEmail(me.handle) ? .email : .phone
        }
    }

    private func save() {
        let settings = repository.settings()
        if kind == .phone, !countryCode.isEmpty, settings.defaultCountryCode != countryCode {
            settings.defaultCountryCode = countryCode
            settings.updatedAt = Date()
        }
        repository.setMyHandle(handle.trimmingCharacters(in: .whitespacesAndNewlines))
        appState.dataDidChange()
        dismiss()
    }
}

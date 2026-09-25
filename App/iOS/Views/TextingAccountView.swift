import SwiftUI
import StoreKit
import SwiftData
import ReminderCore

/// Sign-in, subscription and settings for "Text me" reminders.
struct TextingAccountView: View {
    @ObservedObject private var account = TextingAccount.shared
    @ObservedObject private var store = SubscriptionStore.shared
    @ObservedObject private var appState = AppState.shared
    @State private var isShowingPaywall = false
    @State private var isShowingManage = false
    @State private var isConfirmingDelete = false
    @State private var isConfirmingSignOut = false

    var body: some View {
        Form {
            if !account.isConfigured {
                Section {
                    Text("Texting isn't set up in this build.")
                        .foregroundStyle(.secondary)
                }
            } else if !account.isSignedIn {
                Section {
                    FeatureLine(symbol: "message.fill", text: "Reminders arrive as text messages, no Mac needed.")
                    FeatureLine(symbol: "arrowshape.turn.up.left.fill", text: "Reply SNOOZE, SNOOZE 30 or LATER to get one again. Reply STOP to pause.")
                    FeatureLine(symbol: "lock.fill", text: "Only the reminders you set to \"Text me\" leave this iPhone.")
                }
                TextingSignInSection()
            } else {
                accountSections
            }

            if let error = account.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }
        }
        .navigationTitle("Texts")
        .sheet(isPresented: $isShowingPaywall) { SubscriptionPaywall() }
        .manageSubscriptionsSheet(isPresented: $isShowingManage)
        .confirmationDialog("Delete your texting account?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                Task { await account.deleteAccount() }
            }
        } message: {
            Text("Your phone number, queued texts and text history are deleted from BlueNudge's server. Reminders on this iPhone stay. Cancel the subscription separately in Settings › Apple Account › Subscriptions.")
        }
        .confirmationDialog("Sign out?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign out") { Task { await account.signOut() } }
        } message: {
            Text("Texts already queued are still sent. Sign in again to change them.")
        }
        .task { await account.refresh() }
        .refreshable { await account.refresh() }
    }

    @ViewBuilder
    private var accountSections: some View {
        if account.status != nil, !account.isSubscribed {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Subscribe to start getting texts", systemImage: "message.badge.filled.fill")
                        .font(.headline)
                    Text("Your \"Text me\" reminders are ready and go out as soon as the subscription starts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("See plans") { isShowingPaywall = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.isConfigured)
                }
                .padding(.vertical, 6)
            }
        }

        Section {
            LabeledContent("Phone", value: HandleNormalizer.displayFormat(account.session?.phone ?? ""))
            subscriptionRow
            if let status = account.status {
                LabeledContent("Texts this month") {
                    Text(status.monthlyCap.map { "\(status.sentThisMonth) of \($0)" } ?? "\(status.sentThisMonth)")
                }
                LabeledContent("Queued", value: "\(status.queued)")
            }
        } header: {
            Text("Your texts")
        } footer: {
            if let lastSync = account.lastSync {
                Text("Upcoming texts updated \(lastSync.formatted(.relative(presentation: .named))).")
            }
        }

        Section {
            Toggle("Pause texts", isOn: Binding(
                get: { account.textsPaused },
                set: { paused in Task { await account.setPaused(paused) } }
            ))
            .disabled(account.status == nil)
        } footer: {
            Text("Reply SNOOZE for another text in 10 minutes, or SNOOZE 30, 2H, LATER. Reply STOP to pause every text and START to turn them back on.")
        }

        Section {
            if account.isSubscribed {
                Button("Manage subscription") { isShowingManage = true }
            }
            Button("Sign out") { isConfirmingSignOut = true }
            Button("Delete account", role: .destructive) { isConfirmingDelete = true }
        }
    }

    @ViewBuilder
    private var subscriptionRow: some View {
        if account.isSubscribed {
            LabeledContent("Subscription") {
                if let until = account.status?.entitledUntil {
                    Text("Active, renews \(until.formatted(date: .abbreviated, time: .omitted))")
                } else {
                    Text("Active")
                }
            }
        } else {
            Button {
                isShowingPaywall = true
            } label: {
                LabeledContent("Subscription") {
                    Text(store.isConfigured ? "Subscribe" : "Not available")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .disabled(!store.isConfigured)
            .foregroundStyle(Color.primary)
        }
    }
}

/// The texting account in a sheet, e.g. from onboarding or the reminder editor.
struct TextingSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextingAccountView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Phone number, then the six-digit code.
struct TextingSignInSection: View {
    @ObservedObject private var account = TextingAccount.shared
    @ObservedObject private var store = SubscriptionStore.shared
    @Environment(\.modelContext) private var modelContext
    @State private var phone = ""
    @State private var code = ""

    var body: some View {
        if let sentTo = account.codeSentTo {
            Section {
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button {
                    Task { await account.verify(code: code) }
                } label: {
                    HStack {
                        Text("Verify")
                        if account.isWorking { Spacer(); ProgressView() }
                    }
                }
                .disabled(code.filter(\.isNumber).count < 6 || account.isWorking)
                Button("Use a different number") {
                    account.codeSentTo = nil
                    code = ""
                }
            } header: {
                Text("Enter the code")
            } footer: {
                Text("We texted a code to \(HandleNormalizer.displayFormat(sentTo)).")
            }
        } else {
            Section {
                TextField("Mobile number", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                Button {
                    Task { await account.sendCode(to: phone, countryCode: countryCode) }
                } label: {
                    HStack {
                        Text("Text me a code")
                        if account.isWorking { Spacer(); ProgressView() }
                    }
                }
                .disabled(phone.filter(\.isNumber).count < 7 || account.isWorking)
            } header: {
                Text("Sign in with your phone number")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your reminders are texted to this number. By continuing, you agree to get your reminder texts from BlueNudge. Message frequency varies with your reminders. Message and data rates may apply. Reply HELP for help, STOP to opt out.")
                    HStack(spacing: 16) {
                        if let url = store.termsURL { Link("Terms of use", destination: url) }
                        if let url = store.privacyPolicyURL { Link("Privacy policy", destination: url) }
                    }
                }
            }
        }
    }

    private var countryCode: String {
        Repository(context: modelContext).existingSettings()?.defaultCountryCode
            ?? CallingCodes.callingCode(forRegion: Locale.current.region?.identifier)
    }
}

/// Apple's subscription sheet, tied to the signed-in account.
struct SubscriptionPaywall: View {
    @ObservedObject private var account = TextingAccount.shared
    @ObservedObject private var store = SubscriptionStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let accountToken = account.session?.userID
        SubscriptionStoreView(productIDs: store.productIDs) {
            VStack(spacing: 12) {
                Image(systemName: "message.badge.filled.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                Text("BlueNudge Texts")
                    .font(.largeTitle.bold())
                Text("Your reminders as real text messages, on any iPhone. Reply SNOOZE to get one again later.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .storeButton(.visible, for: .restorePurchases)
        .inAppPurchaseOptions { _ in
            // Ties the purchase to this account, so the server knows whose it is.
            guard let accountToken else { return [] }
            return [.appAccountToken(accountToken)]
        }
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success(let verification)) = result {
                await store.handle(verification)
                await MainActor.run { dismiss() }
            }
        }
        .modifier(PolicyLinks(privacy: store.privacyPolicyURL, terms: store.termsURL))
        .onDisappear {
            // Picks up a restored purchase, which doesn't report a completion.
            Task { await store.claimCurrentEntitlements() }
        }
    }
}

private struct PolicyLinks: ViewModifier {
    let privacy: URL?
    let terms: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let privacy, let terms {
            content
                .subscriptionStorePolicyDestination(url: privacy, for: .privacyPolicy)
                .subscriptionStorePolicyDestination(url: terms, for: .termsOfService)
        } else {
            content
        }
    }
}

struct FeatureLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            Text(text)
        }
    }
}

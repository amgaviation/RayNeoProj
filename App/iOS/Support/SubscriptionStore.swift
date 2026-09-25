import Foundation
import StoreKit

/// The "BlueNudge Texts" auto-renewable subscription. StoreKit handles the
/// purchase; every verified transaction is passed to the server, which checks it
/// with Apple before unlocking texts.
@MainActor
final class SubscriptionStore: ObservableObject {
    static let shared = SubscriptionStore()

    /// From Info.plist (BNSubscriptionProductIDs), in display order.
    let productIDs: [String]
    let privacyPolicyURL: URL?
    let termsURL: URL?

    @Published private(set) var hasEntitlement = false
    private var updatesTask: Task<Void, Never>?

    var isConfigured: Bool { !productIDs.isEmpty }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        productIDs = (info["BNSubscriptionProductIDs"] as? String ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        privacyPolicyURL = (info["BNPrivacyPolicyURL"] as? String).flatMap(Self.httpsURL)
        termsURL = (info["BNTermsURL"] as? String).flatMap(Self.httpsURL)
    }

    /// Listens for renewals, purchases on other devices and refunds.
    func start() {
        guard updatesTask == nil, !DemoMode.isEnabled else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
    }

    /// Sends the current subscription to the server, e.g. after signing in or on launch.
    func claimCurrentEntitlements() async {
        guard !DemoMode.isEnabled else { return }
        var found = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, productIDs.contains(transaction.productID) else { continue }
            if transaction.revocationDate == nil {
                found = true
                await TextingAccount.shared.claimSubscription(transactionID: transaction.id)
            }
        }
        hasEntitlement = found
    }

    /// Called by the store view after a purchase.
    func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if productIDs.contains(transaction.productID) {
            hasEntitlement = transaction.revocationDate == nil
                && (transaction.expirationDate.map { $0 > Date() } ?? true)
            await TextingAccount.shared.claimSubscription(transactionID: transaction.id)
        }
        await transaction.finish()
    }

    private static func httpsURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme == "https" else { return nil }
        return url
    }
}

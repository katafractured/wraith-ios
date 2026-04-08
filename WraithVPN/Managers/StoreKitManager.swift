// StoreKitManager.swift
// WraithVPN
//
// Manages the StoreKit 2 purchase flow:
//   1. Loads product metadata from App Store Connect
//   2. Initiates purchase with App.store().purchase()
//   3. Verifies the transaction locally (JWS) with Transaction.currentEntitlement
//   4. Calls /v1/token/validate/apple to exchange for a Wraith subscription token
//   5. Stores the token in Keychain and publishes subscription state

import Foundation
import StoreKit
import Combine

// MARK: - Product IDs

enum WraithProduct: String, CaseIterable {
    case armorMonthly = "com.katafract.wraith.monthly"
    case armorAnnual  = "com.katafract.wraith.annual"
    case seatPack5    = "com.katafract.wraith.seats.5"

    var displayName: String {
        switch self {
        case .armorMonthly: return "WraithVPN — Monthly"
        case .armorAnnual:  return "WraithVPN — Annual"
        case .seatPack5:    return "5 Device Slots"
        }
    }
}

// MARK: - Manager

@MainActor
final class StoreKitManager: ObservableObject {

    // MARK: Published

    @Published var products: [Product] = []
    @Published var isLoading: Bool = false
    @Published var purchaseError: String? = nil
    @Published var subscription: SubscriptionInfo? = nil
    @Published var hasPurchased: Bool = false
    @Published var isCheckingEntitlements: Bool = true
    @Published var seatPurchaseError: String? = nil
    @Published var isPurchasingSeatPack: Bool = false

    // MARK: Private

    private var transactionListener: Task<Void, Error>?
    private let bundleId = Bundle.main.bundleIdentifier ?? "com.katafract.wraith"

    // MARK: - Init

    init() {
        transactionListener = listenForTransactions()
        Task {
            await reloadFromKeychain()
            await fetchProducts()
        }
        // When APIClient detects a 401, credentials are already cleared.
        // Reset local subscription state so the UI routes to the paywall.
        NotificationCenter.default.addObserver(
            forName: .authTokenInvalidated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.subscription = nil
                self?.hasPurchased = false
            }
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Product loading

    func fetchProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let ids = Set(WraithProduct.allCases.map(\.rawValue))
            products = try await Product.products(for: ids)
                .sorted { $0.price < $1.price }
        } catch {
            purchaseError = "Could not load products: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        purchaseError = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let jws = verification.jwsRepresentation
                let transaction = try checkVerified(verification)
                await handleTransaction(transaction, jwsRepresentation: jws)
                await transaction.finish()

            case .userCancelled:
                break  // No-op — user backed out

            case .pending:
                purchaseError = "Purchase is pending approval (e.g. Ask to Buy)."

            @unknown default:
                purchaseError = "Unknown purchase result."
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Restore

    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }
        purchaseError = nil

        do {
            try await AppStore.sync()
        } catch {
            purchaseError = "Restore failed: \(error.localizedDescription)"
        }
        await reloadFromKeychain()
    }

    // MARK: - Seat pack purchase

    /// Purchase a 5-seat consumable pack and apply it to the backend token.
    func purchaseSeatPack() async {
        guard let product = products.first(where: { $0.id == WraithProduct.seatPack5.rawValue }) else {
            seatPurchaseError = "Seat pack not available. Try again later."
            return
        }
        seatPurchaseError = nil
        isPurchasingSeatPack = true
        defer { isPurchasingSeatPack = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let jws = verification.jwsRepresentation
                let transaction = try checkVerified(verification)
                try await applySeats(transaction: transaction, jws: jws)
                await transaction.finish()
            case .userCancelled:
                break
            case .pending:
                seatPurchaseError = "Purchase pending approval."
            @unknown default:
                seatPurchaseError = "Unknown purchase result."
            }
        } catch {
            seatPurchaseError = error.localizedDescription
        }
    }

    private func applySeats(transaction: Transaction, jws: String) async throws {
        let _ = try await APIClient.shared.addSeats(
            jwsTransaction:        jws,
            productId:             transaction.productID,
            transactionId:         String(transaction.id),
            originalTransactionId: String(transaction.originalID),
            bundleId:              bundleId
        )
    }

    // MARK: - Sign-out / revoke

    func signOut() {
        KeychainHelper.shared.delete(for: .subscriptionToken)
        KeychainHelper.shared.delete(for: .tokenExpiresAt)
        KeychainHelper.shared.delete(for: .tokenPlan)
        UserDefaults.standard.removeObject(forKey: "hasUnlockedFreeTier")
        subscription = nil
        hasPurchased = false
    }

    // MARK: - Private helpers

    /// Checks that the JWS-signed transaction is valid; throws if not.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }

    /// Called for every verified transaction — exchanges it for a backend token.
    private func handleTransaction(_ transaction: Transaction, jwsRepresentation: String) async {
        do {
            let tokenResp = try await APIClient.shared.validateApplePurchase(
                transactionId:         String(transaction.id),
                originalTransactionId: String(transaction.originalID),
                productId:             transaction.productID,
                bundleId:              bundleId,
                jwsTransaction:        jwsRepresentation
            )
            try persistToken(tokenResp)
            await reloadFromKeychain()
        } catch {
            purchaseError = "Could not activate subscription: \(error.localizedDescription)"
        }
    }

    private func persistToken(_ resp: TokenResponse) throws {
        try KeychainHelper.shared.save(resp.token,     for: .subscriptionToken)
        try KeychainHelper.shared.save(resp.expiresAt, for: .tokenExpiresAt)
        try KeychainHelper.shared.save(resp.plan,      for: .tokenPlan)
    }

    /// Reads stored token from Keychain and populates `subscription`.
    func reloadFromKeychain() async {
        defer {
            Task { @MainActor in self.isCheckingEntitlements = false }
        }
        guard let token   = KeychainHelper.shared.readOptional(for: .subscriptionToken),
              let plan     = KeychainHelper.shared.readOptional(for: .tokenPlan) else {
            // No stored token — check StoreKit entitlements anyway
            await checkCurrentEntitlements()
            return
        }

        let expiresAt: Date?
        if let expStr = KeychainHelper.shared.readOptional(for: .tokenExpiresAt) {
            expiresAt = ISO8601DateFormatter().date(from: expStr)
        } else {
            expiresAt = nil
        }

        subscription = SubscriptionInfo(plan: plan, expiresAt: expiresAt, token: token)
        hasPurchased = !(subscription?.isExpired ?? true)
    }

    /// Walk current entitlements and process any unfinished transactions.
    private func checkCurrentEntitlements() async {
        for await result in Transaction.currentEntitlements {
            let jws = result.jwsRepresentation
            guard let transaction = try? checkVerified(result) else { continue }
            await handleTransaction(transaction, jwsRepresentation: jws)
            await transaction.finish()
        }
    }

    /// Background listener — handles transactions completed outside the app
    /// (e.g. Ask to Buy approval, subscription renewal).
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { break }
                do {
                    let jws = result.jwsRepresentation
                    let transaction = try await self.checkVerified(result)
                    await self.handleTransaction(transaction, jwsRepresentation: jws)
                    await transaction.finish()
                } catch {
                    // Verification failed — ignore this transaction
                }
            }
        }
    }
}

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

enum WraithTier: Int, CaseIterable {
    case haven      = 0  // Free
    case enclave    = 1  // $8/mo · $64/yr
    case sovereign  = 2  // $18/mo · $144/yr
    case seats      = 3  // Device slots add-on

    var displayName: String {
        switch self {
        case .haven:      return "Haven"
        case .enclave:    return "Enclave"
        case .sovereign:  return "Sovereign"
        case .seats:      return "Device Slots"
        }
    }

    var accentColorHex: String {
        switch self {
        case .haven:      return "#38bdf8"
        case .enclave:    return "#a78bfa"
        case .sovereign:  return "#f59e0b"
        case .seats:      return "#6b7280"
        }
    }

    var features: [String] {
        switch self {
        case .haven:
            return [
                "Ad & tracker blocking · 24/7",
                "DoH DNS profile · all networks",
                "Works on all apps",
                "No account required"
            ]
        case .enclave:
            return [
                "Everything in Haven",
                "Single-hop WireGuard VPN",
                "10 global WraithGate exit nodes",
                "Kill switch · 5 devices",
                "DNS tier picker",
                "50 AI credits/month"
            ]
        case .sovereign:
            return [
                "Everything in Enclave",
                "Multi-hop routing (2 nodes)",
                "Entry + exit node separation",
                "1 TB Vaultyx storage",
                "Cross-device sync",
                "Priority support"
            ]
        case .seats:
            return ["Adds 5 device slots to your current plan"]
        }
    }
}

enum WraithPeriod {
    case monthly
    case annual
    case oneTime

    var label: String {
        switch self {
        case .monthly:  return "per month"
        case .annual:   return "per year"
        case .oneTime:  return "one-time"
        }
    }
}

enum WraithProduct: String, CaseIterable {
    // Grandfathered (old) products — keep for existing subscribers
    case havenProMonthly    = "com.katafract.haven.pro.monthly"
    case havenProAnnual     = "com.katafract.haven.pro.annual"
    case enclavePlusMonthly = "com.katafract.wraith.plus.monthly"
    case enclavePlusAnnual  = "com.katafract.wraith.plus.annual"

    // New v2 products (2026-04-20)
    case enclaveMonthly     = "com.katafract.enclave.monthly"     // $8/mo
    case enclaveAnnual      = "com.katafract.enclave.annual"      // $64/yr
    case sovereignMonthly   = "com.katafract.sovereign.monthly"   // $18/mo
    case sovereignAnnual    = "com.katafract.sovereign.annual"    // $144/yr

    // Device slots add-on
    case seatPack5          = "com.katafract.wraith.seats.5"

    var displayName: String {
        switch self {
        case .havenProMonthly:    return "Haven Pro — Monthly (Grandfathered)"
        case .havenProAnnual:     return "Haven Pro — Annual (Grandfathered)"
        case .enclaveMonthly:     return "Enclave — Monthly"
        case .enclaveAnnual:      return "Enclave — Annual"
        case .enclavePlusMonthly: return "Enclave+ — Monthly (Grandfathered)"
        case .enclavePlusAnnual:  return "Enclave+ — Annual (Grandfathered)"
        case .sovereignMonthly:   return "Sovereign — Monthly"
        case .sovereignAnnual:    return "Sovereign — Annual"
        case .seatPack5:          return "5 Device Slots"
        }
    }

    var tier: WraithTier {
        switch self {
        case .havenProMonthly, .havenProAnnual:
            return .haven
        case .enclaveMonthly, .enclaveAnnual:
            return .enclave
        case .enclavePlusMonthly, .enclavePlusAnnual:
            return .sovereign  // Old Enclave+ becomes Sovereign
        case .sovereignMonthly, .sovereignAnnual:
            return .sovereign
        case .seatPack5:
            return .seats
        }
    }

    var period: WraithPeriod {
        switch self {
        case .havenProMonthly, .enclaveMonthly, .enclavePlusMonthly, .sovereignMonthly:
            return .monthly
        case .havenProAnnual, .enclaveAnnual, .enclavePlusAnnual, .sovereignAnnual:
            return .annual
        case .seatPack5:
            return .oneTime
        }
    }

    /// The corresponding annual product for this monthly product (nil if already annual or one-time).
    var annualVariant: WraithProduct? {
        switch self {
        case .enclaveMonthly:    return .enclaveAnnual
        case .sovereignMonthly:  return .sovereignAnnual
        default:                 return nil
        }
    }

    /// The corresponding monthly product for this annual product (nil if already monthly or one-time).
    var monthlyVariant: WraithProduct? {
        switch self {
        case .enclaveAnnual:     return .enclaveMonthly
        case .sovereignAnnual:   return .sovereignMonthly
        default:                 return nil
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
    @Published var hasPurchased:   Bool = false
    @Published var isHavenOnly:    Bool = false
    @Published var hasDNSSettings: Bool = false
    @Published var hasVPN:         Bool = false
    @Published var hasMultiHop:    Bool = false
    @Published var hasSovereign:   Bool = false
    @Published var isFounder:      Bool = false
    @Published var isAdmin:        Bool = false
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
            // Mock products for screenshots
            if ScreenshotMode.isActive {
                if ScreenshotMode.mockSubscribed {
                    subscription = SubscriptionInfo(plan: "enclave", expiresAt: Date(timeIntervalSinceNow: 86400 * 365), token: "mock-token")
                    hasPurchased = true
                }
                if ScreenshotMode.mockUnsubscribed {
                    subscription = nil
                    hasPurchased = false
                }
            }
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
                self?.hasPurchased   = false
                self?.hasDNSSettings = false
                self?.hasSovereign   = false
                self?.isFounder      = false
                self?.isAdmin        = false
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

    // MARK: - Founder access code redemption

    /// Validates an access code against the backend and saves it as the active token.
    /// Founder tokens (`kf_...`) sync via iCloud Keychain to all the user's devices.
    func redeemAccessCode(_ code: String) async throws {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        let info    = try await APIClient.shared.validateToken(trimmed)
        guard info.plan != "haven_free" else {
            throw APIError.httpError(statusCode: 403, body: "Code does not grant a paid plan.")
        }
        // Founders get no expiry; others use a 1-year default since we don't know the real expiry here.
        let expiresAt = info.isFounder
            ? ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: 36500 * 86400))
            : (info.expiresAt ?? ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: 365 * 86400)))
        try KeychainHelper.shared.save(trimmed,                       for: .subscriptionToken)
        try KeychainHelper.shared.save(info.plan,                     for: .tokenPlan)
        try KeychainHelper.shared.save(expiresAt,                     for: .tokenExpiresAt)
        try KeychainHelper.shared.save(info.isAdmin   ? "1" : "0",   for: .tokenIsAdmin)
        try KeychainHelper.shared.save(info.isFounder ? "1" : "0",   for: .tokenIsFounder)
        await reloadFromKeychain()
    }

    // MARK: - Sign-out / revoke

    func signOut() {
        KeychainHelper.shared.delete(for: .subscriptionToken)
        KeychainHelper.shared.delete(for: .tokenExpiresAt)
        KeychainHelper.shared.delete(for: .tokenPlan)
        KeychainHelper.shared.delete(for: .tokenIsAdmin)
        KeychainHelper.shared.delete(for: .tokenIsFounder)
        UserDefaults.standard.removeObject(forKey: "hasUnlockedFreeTier")
        subscription = nil
        hasPurchased   = false
        isHavenOnly    = false
        hasDNSSettings = false
        hasVPN         = false
        hasMultiHop    = false
        hasSovereign   = false
        isFounder      = false
        isAdmin        = false
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
            applyKeychainState()  // update published state without re-triggering entitlement check
        } catch {
            purchaseError = "Could not activate subscription: \(error.localizedDescription)"
        }
    }

    private func persistToken(_ resp: TokenResponse) throws {
        guard !resp.token.isEmpty else { return }  // server returned empty on renewal — keep existing Keychain token
        // Don't overwrite a founder kf_ token with a non-founder IAP token.
        if KeychainHelper.shared.readOptional(for: .tokenIsFounder) == "1" && !resp.isFounder {
            return
        }
        try KeychainHelper.shared.save(resp.token,                         for: .subscriptionToken)
        try KeychainHelper.shared.save(resp.expiresAt,                     for: .tokenExpiresAt)
        try KeychainHelper.shared.save(resp.plan,                          for: .tokenPlan)
        try KeychainHelper.shared.save(resp.isAdmin   ? "1" : "0",        for: .tokenIsAdmin)
        try KeychainHelper.shared.save(resp.isFounder ? "1" : "0",        for: .tokenIsFounder)
    }

    /// Updates published subscription state from keychain without spawning a background entitlement check.
    /// Use this inside entitlement processing paths (handleTransaction) to avoid re-entrant loops.
    private func applyKeychainState() {
        guard let token = KeychainHelper.shared.readOptional(for: .subscriptionToken),
              let plan  = KeychainHelper.shared.readOptional(for: .tokenPlan) else { return }
        let expiresAt: Date?
        if let expStr = KeychainHelper.shared.readOptional(for: .tokenExpiresAt) {
            expiresAt = ISO8601DateFormatter().date(from: expStr)
        } else {
            expiresAt = nil
        }
        subscription   = SubscriptionInfo(plan: plan, expiresAt: expiresAt, token: token)
        hasPurchased   = !(subscription?.isExpired ?? true)
        isHavenOnly    = subscription?.isHavenOnly    ?? false
        hasDNSSettings = subscription?.hasDNSSettings ?? false
        hasVPN         = subscription?.hasVPN         ?? false
        hasMultiHop    = subscription?.hasMultiHop    ?? false
        isFounder      = KeychainHelper.shared.readOptional(for: .tokenIsFounder) == "1"
        hasSovereign   = (subscription?.hasSovereign ?? false) || isFounder
        isAdmin        = KeychainHelper.shared.readOptional(for: .tokenIsAdmin)   == "1"
    }

    /// Reads stored token from Keychain and populates `subscription`.
    /// - When a cached token exists: populates state immediately (no network), then
    ///   refreshes StoreKit entitlements in the background so the UI is never blocked.
    /// - When no cached token: waits for the StoreKit check before releasing the
    ///   splash screen — this is the IAP auto-recovery path after reinstall.
    func reloadFromKeychain() async {
        // Load cached state from Keychain (instant, no network)
        if let token = KeychainHelper.shared.readOptional(for: .subscriptionToken),
           let plan  = KeychainHelper.shared.readOptional(for: .tokenPlan) {
            let expiresAt: Date?
            if let expStr = KeychainHelper.shared.readOptional(for: .tokenExpiresAt) {
                expiresAt = ISO8601DateFormatter().date(from: expStr)
            } else {
                expiresAt = nil
            }
            subscription = SubscriptionInfo(plan: plan, expiresAt: expiresAt, token: token)
            hasPurchased   = !(subscription?.isExpired ?? true)
            isHavenOnly    = subscription?.isHavenOnly    ?? false
            hasDNSSettings = subscription?.hasDNSSettings ?? false
            hasVPN         = subscription?.hasVPN         ?? false
            hasMultiHop    = subscription?.hasMultiHop    ?? false
            isFounder      = KeychainHelper.shared.readOptional(for: .tokenIsFounder) == "1"
            hasSovereign   = (subscription?.hasSovereign ?? false) || isFounder
            isAdmin        = KeychainHelper.shared.readOptional(for: .tokenIsAdmin)   == "1"

            // Release the splash screen immediately — we have a valid cached token.
            // Silently check StoreKit in the background for renewals/upgrades.
            isCheckingEntitlements = false
            Task.detached(priority: .background) { [weak self] in
                await self?.checkCurrentEntitlements()
            }
        } else {
            // No cached token — must wait for StoreKit check (IAP reinstall recovery).
            defer {
                Task { @MainActor in self.isCheckingEntitlements = false }
            }
            await checkCurrentEntitlements()
        }
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

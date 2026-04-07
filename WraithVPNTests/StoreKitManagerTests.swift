// StoreKitManagerTests.swift
// WraithVPNTests
//
// Tests for StoreKitManager's token persistence, subscription state machine,
// and sign-out behavior. Uses the real Keychain (cleaned up per test).
// StoreKit 2 network calls are not exercised here.

import XCTest
@testable import WraithVPN

@MainActor
final class StoreKitManagerTests: XCTestCase {

    private var manager: StoreKitManager!
    private let keychain = KeychainHelper.shared

    override func setUp() async throws {
        try await super.setUp()
        keychain.deleteAll()
        manager = StoreKitManager()
    }

    override func tearDown() async throws {
        keychain.deleteAll()
        try await super.tearDown()
    }

    // MARK: - reloadFromKeychain

    func testReloadFromKeychain_validToken_setsHasPurchased() async throws {
        // Seed Keychain with a valid, non-expired token
        let futureISO = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: 86400))
        try keychain.save("tok_valid", for: .subscriptionToken)
        try keychain.save("veil",      for: .tokenPlan)
        try keychain.save(futureISO,   for: .tokenExpiresAt)

        await manager.reloadFromKeychain()

        XCTAssertTrue(manager.hasPurchased)
        XCTAssertNotNil(manager.subscription)
        XCTAssertEqual(manager.subscription?.plan,  "veil")
        XCTAssertEqual(manager.subscription?.token, "tok_valid")
    }

    func testReloadFromKeychain_expiredToken_setsFalse() async throws {
        let pastISO = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -86400))
        try keychain.save("tok_expired", for: .subscriptionToken)
        try keychain.save("haven",       for: .tokenPlan)
        try keychain.save(pastISO,       for: .tokenExpiresAt)

        await manager.reloadFromKeychain()

        XCTAssertFalse(manager.hasPurchased)
    }

    func testReloadFromKeychain_founderToken_nilExpiry_isNotExpired() async throws {
        // Founder tokens have nil expiresAt — should not be considered expired
        try keychain.save("tok_founder", for: .subscriptionToken)
        try keychain.save("founder",     for: .tokenPlan)
        // No tokenExpiresAt saved

        await manager.reloadFromKeychain()

        XCTAssertTrue(manager.hasPurchased)
        XCTAssertNil(manager.subscription?.expiresAt)
    }

    func testReloadFromKeychain_noToken_setsNotPurchased() async throws {
        // No Keychain data at all — hasPurchased should stay false
        // (checkCurrentEntitlements will run but find nothing in test env)
        await manager.reloadFromKeychain()

        XCTAssertFalse(manager.hasPurchased)
    }

    func testReloadFromKeychain_invalidISO8601ExpiresAt_treatedAsNilDate() async throws {
        try keychain.save("tok_ok",      for: .subscriptionToken)
        try keychain.save("veil",        for: .tokenPlan)
        try keychain.save("not-a-date",  for: .tokenExpiresAt)

        await manager.reloadFromKeychain()

        // Invalid date → nil → isExpired = false → hasPurchased = true
        XCTAssertTrue(manager.hasPurchased)
        XCTAssertNil(manager.subscription?.expiresAt)
    }

    // MARK: - signOut

    func testSignOut_clearsSubscription() async throws {
        try keychain.save("tok",    for: .subscriptionToken)
        try keychain.save("veil",   for: .tokenPlan)
        try keychain.save(ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: 86400)), for: .tokenExpiresAt)
        await manager.reloadFromKeychain()
        XCTAssertTrue(manager.hasPurchased)

        manager.signOut()

        XCTAssertFalse(manager.hasPurchased)
        XCTAssertNil(manager.subscription)
    }

    func testSignOut_clearsKeychainTokens() throws {
        try keychain.save("tok",  for: .subscriptionToken)
        try keychain.save("plan", for: .tokenPlan)
        try keychain.save("exp",  for: .tokenExpiresAt)

        manager.signOut()

        XCTAssertNil(keychain.readOptional(for: .subscriptionToken))
        XCTAssertNil(keychain.readOptional(for: .tokenPlan))
        XCTAssertNil(keychain.readOptional(for: .tokenExpiresAt))
    }

    func testSignOut_doesNotClearWireGuardKeys() throws {
        try keychain.save("wg-priv", for: .wireguardPrivKey)
        try keychain.save("wg-pub",  for: .wireguardPubKey)

        manager.signOut()

        // WireGuard keys should survive sign-out (peer is still provisioned)
        XCTAssertEqual(keychain.readOptional(for: .wireguardPrivKey), "wg-priv")
        XCTAssertEqual(keychain.readOptional(for: .wireguardPubKey),  "wg-pub")
    }

    // MARK: - Subscription plan display names via SubscriptionInfo

    func testSubscriptionInfo_planDisplayNames_allKnown() {
        let plans: [(String, String)] = [
            ("founder",        "Founder"),
            ("total",          "Founder"),
            ("total_annual",   "Founder"),
            ("haven",          "Haven DNS"),
            ("veil",           "WraithVPN"),
            ("vpn_armor",      "WraithVPN"),
            ("veil_annual",    "WraithVPN Annual"),
            ("enclave",        "Enclave"),
            ("enclave_annual", "Enclave"),
        ]
        for (plan, expected) in plans {
            let sub = SubscriptionInfo(plan: plan, expiresAt: nil, token: "t")
            XCTAssertEqual(sub.planDisplayName, expected, "Failed for plan: \(plan)")
        }
    }

    // MARK: - hasPurchased logic

    func testHasPurchased_falseByDefault() {
        // Fresh manager with empty Keychain
        let fresh = StoreKitManager()
        // hasPurchased starts false before async reloadFromKeychain completes
        XCTAssertFalse(fresh.hasPurchased)
    }
}

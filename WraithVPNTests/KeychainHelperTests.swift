// KeychainHelperTests.swift
// WraithVPNTests
//
// Integration tests for KeychainHelper using the real Security framework.
// Each test cleans up after itself via tearDown.

import XCTest
@testable import WraithVPN

final class KeychainHelperTests: XCTestCase {

    private let keychain = KeychainHelper.shared

    override func tearDown() {
        super.tearDown()
        keychain.deleteAll()
    }

    // MARK: - Save & Read

    func testSave_andRead_roundTrip() throws {
        try keychain.save("hello-world", for: .subscriptionToken)
        let result = try keychain.read(for: .subscriptionToken)
        XCTAssertEqual(result, "hello-world")
    }

    func testSave_overwritesExistingValue() throws {
        try keychain.save("first",  for: .subscriptionToken)
        try keychain.save("second", for: .subscriptionToken)
        let result = try keychain.read(for: .subscriptionToken)
        XCTAssertEqual(result, "second")
    }

    func testSave_multipleKeys_areIndependent() throws {
        try keychain.save("token-value",   for: .subscriptionToken)
        try keychain.save("plan-value",    for: .tokenPlan)
        try keychain.save("expires-value", for: .tokenExpiresAt)

        XCTAssertEqual(try keychain.read(for: .subscriptionToken), "token-value")
        XCTAssertEqual(try keychain.read(for: .tokenPlan),         "plan-value")
        XCTAssertEqual(try keychain.read(for: .tokenExpiresAt),    "expires-value")
    }

    func testSave_unicodeString_roundTrips() throws {
        let emoji = "🔐 Wraith VPN 🌐"
        try keychain.save(emoji, for: .subscriptionToken)
        XCTAssertEqual(try keychain.read(for: .subscriptionToken), emoji)
    }

    func testSave_emptyString_roundTrips() throws {
        try keychain.save("", for: .subscriptionToken)
        XCTAssertEqual(try keychain.read(for: .subscriptionToken), "")
    }

    // MARK: - readOptional

    func testReadOptional_returnsNil_whenKeyNotSet() {
        XCTAssertNil(keychain.readOptional(for: .subscriptionToken))
    }

    func testReadOptional_returnsValue_whenKeySet() throws {
        try keychain.save("mytoken", for: .subscriptionToken)
        XCTAssertEqual(keychain.readOptional(for: .subscriptionToken), "mytoken")
    }

    func testReadOptional_returnsNil_afterDelete() throws {
        try keychain.save("mytoken", for: .subscriptionToken)
        keychain.delete(for: .subscriptionToken)
        XCTAssertNil(keychain.readOptional(for: .subscriptionToken))
    }

    // MARK: - Delete

    func testDelete_removesValue() throws {
        try keychain.save("token", for: .subscriptionToken)
        keychain.delete(for: .subscriptionToken)
        XCTAssertNil(keychain.readOptional(for: .subscriptionToken))
    }

    func testDelete_nonexistentKey_doesNotThrow() {
        // Should be silent even if key doesn't exist
        XCTAssertNoThrow(keychain.delete(for: .wireguardPrivKey))
    }

    // MARK: - deleteAll

    func testDeleteAll_removesAllKeys() throws {
        try keychain.save("tok",  for: .subscriptionToken)
        try keychain.save("plan", for: .tokenPlan)
        try keychain.save("exp",  for: .tokenExpiresAt)
        try keychain.save("priv", for: .wireguardPrivKey)

        keychain.deleteAll()

        XCTAssertNil(keychain.readOptional(for: .subscriptionToken))
        XCTAssertNil(keychain.readOptional(for: .tokenPlan))
        XCTAssertNil(keychain.readOptional(for: .tokenExpiresAt))
        XCTAssertNil(keychain.readOptional(for: .wireguardPrivKey))
    }

    func testDeleteAll_onEmptyKeychain_doesNotThrow() {
        XCTAssertNoThrow(keychain.deleteAll())
    }

    // MARK: - All known keys

    func testAllKeys_canBeWrittenAndRead() throws {
        // Verify every KeychainHelper.Key can round-trip through the keychain
        let testValue = "test-value"
        for key in KeychainHelper.Key.allCases {
            try keychain.save(testValue, for: key)
            let result = keychain.readOptional(for: key)
            XCTAssertEqual(result, testValue, "Round-trip failed for key: \(key.rawValue)")
            keychain.delete(for: key)
        }
    }

    // MARK: - WireGuard keys

    func testWireGuardKeys_independentOfSubscriptionKeys() throws {
        try keychain.save("wg-priv",  for: .wireguardPrivKey)
        try keychain.save("wg-pub",   for: .wireguardPubKey)
        try keychain.save("tok",      for: .subscriptionToken)

        XCTAssertEqual(try keychain.read(for: .wireguardPrivKey), "wg-priv")
        XCTAssertEqual(try keychain.read(for: .wireguardPubKey),  "wg-pub")
        XCTAssertEqual(try keychain.read(for: .subscriptionToken), "tok")
    }
}

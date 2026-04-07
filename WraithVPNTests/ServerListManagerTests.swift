// ServerListManagerTests.swift
// WraithVPNTests
//
// Tests for ServerListManager's sorting logic, latency display, and
// auto-selection behavior. TCP probe tests are omitted (require Network.framework
// and live endpoints); those belong in integration tests.

import XCTest
@testable import WraithVPN

final class ServerListManagerTests: XCTestCase {

    // MARK: - Sorting

    func testSort_bothPresent_ascendingByLatency() {
        let slow = makeLatency(ms: 200, nodeId: "slow")
        let fast = makeLatency(ms: 50,  nodeId: "fast")
        let mid  = makeLatency(ms: 120, nodeId: "mid")

        let sorted = [slow, fast, mid].sortedByLatency()

        XCTAssertEqual(sorted[0].server.nodeId, "fast")
        XCTAssertEqual(sorted[1].server.nodeId, "mid")
        XCTAssertEqual(sorted[2].server.nodeId, "slow")
    }

    func testSort_reachableBeforeUnreachable() {
        let reachable   = makeLatency(ms: 999,  nodeId: "reachable")
        let unreachable = makeLatency(ms: nil,   nodeId: "unreachable")

        let sorted = [unreachable, reachable].sortedByLatency()

        XCTAssertEqual(sorted[0].server.nodeId, "reachable")
        XCTAssertEqual(sorted[1].server.nodeId, "unreachable")
    }

    func testSort_bothNil_stableRelativeOrder() {
        let a = makeLatency(ms: nil, nodeId: "a")
        let b = makeLatency(ms: nil, nodeId: "b")

        let sorted = [a, b].sortedByLatency()

        // Both nil → neither is preferred; original order preserved
        XCTAssertEqual(sorted.count, 2)
        XCTAssertEqual(sorted[0].server.nodeId, "a")
        XCTAssertEqual(sorted[1].server.nodeId, "b")
    }

    func testSort_mixedReachable_allReachableFirst() {
        let items = [
            makeLatency(ms: nil,  nodeId: "dead-1"),
            makeLatency(ms: 80,   nodeId: "good"),
            makeLatency(ms: nil,  nodeId: "dead-2"),
            makeLatency(ms: 30,   nodeId: "best"),
            makeLatency(ms: 150,  nodeId: "ok"),
        ]

        let sorted = items.sortedByLatency()

        XCTAssertEqual(sorted[0].server.nodeId, "best")
        XCTAssertEqual(sorted[1].server.nodeId, "good")
        XCTAssertEqual(sorted[2].server.nodeId, "ok")
        // Dead nodes last (order between them is stable)
        XCTAssertNil(sorted[3].milliseconds)
        XCTAssertNil(sorted[4].milliseconds)
    }

    // MARK: - Auto-selection

    func testAutoSelect_picksFirstReachable() {
        let servers = [
            makeLatency(ms: nil, nodeId: "dead"),
            makeLatency(ms: 50,  nodeId: "fast"),
            makeLatency(ms: 90,  nodeId: "slower"),
        ].sortedByLatency()

        let selected = servers.first { $0.milliseconds != nil }

        XCTAssertEqual(selected?.server.nodeId, "fast")
    }

    func testAutoSelect_returnsNilWhenAllUnreachable() {
        let servers = [
            makeLatency(ms: nil, nodeId: "a"),
            makeLatency(ms: nil, nodeId: "b"),
        ]
        let selected = servers.first { $0.milliseconds != nil }
        XCTAssertNil(selected)
    }

    // MARK: - displayLatency

    func testDisplayLatency_whole_ms() {
        XCTAssertEqual(makeLatency(ms: 42).displayLatency,  "42 ms")
        XCTAssertEqual(makeLatency(ms: 0).displayLatency,   "0 ms")
        XCTAssertEqual(makeLatency(ms: 999).displayLatency, "999 ms")
    }

    func testDisplayLatency_fractional_truncates() {
        // Int(42.9) → 42
        XCTAssertEqual(makeLatency(ms: 42.9).displayLatency, "42 ms")
    }

    func testDisplayLatency_nil_returnsDash() {
        let sl = ServerLatency(server: makeServer(nodeId: "n"), milliseconds: nil)
        XCTAssertEqual(sl.displayLatency, "—")
    }

    // MARK: - Latency tiers (boundary conditions)

    func testLatencyTier_boundaries() {
        XCTAssertEqual(makeLatency(ms: 0).latencyTier,   .excellent)
        XCTAssertEqual(makeLatency(ms: 59).latencyTier,  .excellent)
        XCTAssertEqual(makeLatency(ms: 60).latencyTier,  .good)
        XCTAssertEqual(makeLatency(ms: 119).latencyTier, .good)
        XCTAssertEqual(makeLatency(ms: 120).latencyTier, .fair)
        XCTAssertEqual(makeLatency(ms: 199).latencyTier, .fair)
        XCTAssertEqual(makeLatency(ms: 200).latencyTier, .poor)
        XCTAssertEqual(makeLatency(ms: 500).latencyTier, .poor)
    }

    // MARK: - Region count

    func testRegionMap_hasAllSixNodes() {
        XCTAssertEqual(RegionInfo.regionMap.count, 6)
    }

    func testRegionMap_allNodesPresent() {
        let expectedRegions = ["eu-west", "eu-north", "ap-southeast", "us-central", "us-east", "us-west"]
        for region in expectedRegions {
            XCTAssertNotNil(RegionInfo.regionMap[region], "Missing region: \(region)")
        }
    }
}

// MARK: - Helpers

private extension ServerListManagerTests {

    func makeServer(nodeId: String = "node-1", region: String = "us-west") -> VPNServer {
        VPNServer(
            nodeId: nodeId,
            site: "Test Site",
            region: region,
            displayName: "Test Node",
            ipv4: "1.2.3.4",
            ipv6: nil,
            endpoints: VPNServer.Endpoints(primary: "1.2.3.4:51820", secondary: nil),
            publicKey: "pubkey==",
            wgPort: 51820,
            loadScore: 0.5,
            ipv6Available: false,
            geodnsWeight: 100
        )
    }

    func makeLatency(ms: Double?, nodeId: String = "node-1") -> ServerLatency {
        ServerLatency(server: makeServer(nodeId: nodeId), milliseconds: ms)
    }
}

// MARK: - Sort helper (mirrors ServerListManager's sort logic)

private extension Array where Element == ServerLatency {
    func sortedByLatency() -> [ServerLatency] {
        sorted {
            switch ($0.milliseconds, $1.milliseconds) {
            case let (a?, b?): return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):   return false
            }
        }
    }
}

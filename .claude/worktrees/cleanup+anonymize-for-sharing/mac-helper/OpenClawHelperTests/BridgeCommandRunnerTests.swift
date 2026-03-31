import XCTest
@testable import OpenClawHelper

final class BridgeCommandRunnerTests: XCTestCase {
    func testActiveFixtureDecodes() throws {
        let data = try fixtureData("bridge-status.active")
        let snapshot = try JSONDecoder().decode(BridgeSnapshot.self, from: data)
        XCTAssertEqual(snapshot.trackingState, .active)
        XCTAssertEqual(snapshot.queueDepth, 0)
        XCTAssertFalse(snapshot.sensitiveMode)
        XCTAssertNil(snapshot.pauseUntil)
    }

    func testPausedFixtureDecodes() throws {
        let data = try fixtureData("bridge-status.paused")
        let snapshot = try JSONDecoder().decode(BridgeSnapshot.self, from: data)
        XCTAssertEqual(snapshot.trackingState, .paused)
        XCTAssertEqual(snapshot.pauseUntil, "indefinite")
        XCTAssertEqual(snapshot.queueDepth, 3)
    }

    func testNeedsAttentionFixtureDecodes() throws {
        let data = try fixtureData("bridge-status.needs-attention")
        let snapshot = try JSONDecoder().decode(BridgeSnapshot.self, from: data)
        XCTAssertEqual(snapshot.daemonLaunchdState, "missing")
        XCTAssertEqual(snapshot.queueDepth, 42)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }
}

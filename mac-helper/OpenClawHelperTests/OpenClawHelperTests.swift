import XCTest
@testable import OpenClawHelper

final class OpenClawHelperTests: XCTestCase {
    func testAppModelStartsActive() {
        let model = AppModel()
        XCTAssertEqual(model.snapshot.trackingState, .active)
        XCTAssertEqual(model.menuBarSymbol, "eye.circle.fill")
    }

    func testTrackingStateSymbols() {
        XCTAssertEqual(BridgeSnapshot.TrackingState.active.menuBarSymbol, "eye.circle.fill")
        XCTAssertEqual(BridgeSnapshot.TrackingState.paused.menuBarSymbol, "pause.circle.fill")
        XCTAssertEqual(BridgeSnapshot.TrackingState.sensitive.menuBarSymbol, "hand.raised.circle.fill")
        XCTAssertEqual(BridgeSnapshot.TrackingState.needsAttention.menuBarSymbol, "exclamationmark.triangle.fill")
    }

    func testPlaceholderSnapshot() {
        let snapshot = BridgeSnapshot.placeholder
        XCTAssertEqual(snapshot.trackingState, .active)
    }
}

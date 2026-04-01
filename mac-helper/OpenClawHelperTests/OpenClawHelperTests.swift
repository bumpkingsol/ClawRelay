import XCTest
@testable import OpenClawHelper

final class OpenClawHelperTests: XCTestCase {
    @MainActor
    func testAppModelStartsActive() {
        let model = AppModel()
        XCTAssertEqual(model.menuBarViewModel.snapshot.trackingState, .active)
        XCTAssertEqual(model.menuBarSymbol, "eye.circle.fill")
    }

    @MainActor
    func testPresentationControllerReopenWithoutVisibleWindowsRequestsControlCenter() {
        let controller = AppPresentationController()
        var showCount = 0
        controller.onOpenControlCenter = {
            showCount += 1
        }
        controller.currentWindowsProvider = { [] }
        controller.activateApp = { }

        controller.handleReopen(hasVisibleWindows: false)

        XCTAssertEqual(showCount, 1)
    }

    @MainActor
    func testPresentationControllerReopenWithVisibleWindowsDoesNotRequestNewWindow() {
        let controller = AppPresentationController()
        var showCount = 0
        controller.onOpenControlCenter = {
            showCount += 1
        }
        controller.currentWindowsProvider = { [] }
        controller.activateApp = { }

        controller.handleReopen(hasVisibleWindows: true)

        XCTAssertEqual(showCount, 0)
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
        XCTAssertEqual(snapshot.productState, .running)
    }
}

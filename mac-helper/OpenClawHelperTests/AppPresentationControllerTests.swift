import AppKit
import XCTest
@testable import OpenClawHelper

final class AppPresentationControllerTests: XCTestCase {
    @MainActor
    func testShowControlCenterFocusesRegisteredWindowWithoutOpeningAnother() {
        let controller = AppPresentationController()
        let window = NSWindow()
        var openCount = 0
        var activateCount = 0

        controller.registerControlCenterWindow(window)
        controller.activateApp = { activateCount += 1 }

        controller.showControlCenter {
            openCount += 1
        }

        XCTAssertEqual(openCount, 0)
        XCTAssertEqual(activateCount, 1)
        XCTAssertTrue(window.isKeyWindow || window.isVisible)
    }

    @MainActor
    func testShowControlCenterRequestsOpenWhenWindowNotRegistered() {
        let controller = AppPresentationController()
        var openCount = 0
        var activateCount = 0
        controller.activateApp = { activateCount += 1 }

        controller.showControlCenter {
            openCount += 1
        }

        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(activateCount, 1)
    }

    @MainActor
    func testHandleReopenWithVisibleWindowsFocusesRegisteredWindow() {
        let controller = AppPresentationController()
        let window = NSWindow()
        var activateCount = 0
        controller.registerControlCenterWindow(window)
        controller.activateApp = { activateCount += 1 }

        let handled = controller.handleReopen(hasVisibleWindows: true)

        XCTAssertTrue(handled)
        XCTAssertEqual(activateCount, 1)
    }
}

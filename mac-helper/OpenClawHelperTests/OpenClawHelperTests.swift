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
    func testPresentationControllerReopenWithoutVisibleWindowsFallsBackToSystemReopen() {
        let controller = AppPresentationController()
        controller.currentWindowsProvider = { [] }
        controller.activateApp = { }

        let handled = controller.handleReopen(hasVisibleWindows: false)

        XCTAssertFalse(handled)
    }

    @MainActor
    func testPresentationControllerReopenWithVisibleWindowsReturnsHandled() {
        let controller = AppPresentationController()
        let window = NSWindow()
        controller.currentWindowsProvider = { [window] }
        controller.activateApp = { }

        let handled = controller.handleReopen(hasVisibleWindows: true)

        XCTAssertTrue(handled)
    }

    @MainActor
    func testAppInstanceCoordinatorAllowsPrimaryInstanceToContinueLaunching() {
        let coordinator = AppInstanceCoordinator()
        var terminateCount = 0
        var postCount = 0
        var activatedPID: pid_t?

        coordinator.currentProcessIdentifier = { 100 }
        coordinator.bundleIdentifierProvider = { "com.openclaw.clawrelay" }
        coordinator.runningApplicationsProvider = { _ in [] }
        coordinator.postShowControlCenterRequest = { _ in postCount += 1 }
        coordinator.activateRunningApplication = { app in
            activatedPID = app.processIdentifier
        }
        coordinator.terminateCurrentApp = { terminateCount += 1 }

        let shouldContinue = coordinator.handleLaunch()

        XCTAssertTrue(shouldContinue)
        XCTAssertEqual(terminateCount, 0)
        XCTAssertEqual(postCount, 0)
        XCTAssertNil(activatedPID)
    }

    @MainActor
    func testAppInstanceCoordinatorHandsOffToExistingInstanceAndTerminates() {
        let coordinator = AppInstanceCoordinator()
        let existingApp = NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        var terminateCount = 0
        var postedBundleIdentifier: String?
        var activatedPID: pid_t?

        coordinator.currentProcessIdentifier = { 999 }
        coordinator.bundleIdentifierProvider = { "com.openclaw.clawrelay" }
        coordinator.runningApplicationsProvider = { _ in [existingApp].compactMap { $0 } }
        coordinator.postShowControlCenterRequest = { bundleIdentifier in
            postedBundleIdentifier = bundleIdentifier
        }
        coordinator.activateRunningApplication = { app in
            activatedPID = app.processIdentifier
        }
        coordinator.terminateCurrentApp = { terminateCount += 1 }

        let shouldContinue = coordinator.handleLaunch()

        XCTAssertFalse(shouldContinue)
        XCTAssertEqual(postedBundleIdentifier, "com.openclaw.clawrelay")
        XCTAssertEqual(activatedPID, existingApp?.processIdentifier)
        XCTAssertEqual(terminateCount, 1)
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

import XCTest
@testable import OpenClawHelper

final class MenuBarViewModelTests: XCTestCase {
    @MainActor
    func testPausedSnapshotPrefersResumeAction() {
        let snapshot = BridgeSnapshot(
            trackingState: .paused,
            pauseUntil: "indefinite",
            sensitiveMode: false,
            queueDepth: 0,
            daemonLaunchdState: "loaded",
            watcherLaunchdState: "loaded"
        )
        let model = MenuBarViewModel.preview(snapshot: snapshot)
        XCTAssertEqual(model.primaryActionTitle, "Resume")
    }

    @MainActor
    func testActiveSnapshotPrefersPauseAction() {
        let model = MenuBarViewModel.preview(snapshot: .placeholder)
        XCTAssertEqual(model.primaryActionTitle, "Pause 15m")
    }
}

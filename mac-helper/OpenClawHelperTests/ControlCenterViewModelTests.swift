import XCTest
@testable import OpenClawHelper

final class ControlCenterViewModelTests: XCTestCase {
    private final class AppLifecycleSpy: AppLifecycleControlling {
        private(set) var quitCallCount = 0
        private(set) var relaunchCallCount = 0

        func quit() {
            quitCallCount += 1
        }

        func relaunch() {
            relaunchCallCount += 1
        }
    }

    private func runnerScript(returning json: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sh")
        let script = """
        #!/bin/bash
        if [ "$1" = "status" ] || [ "$1" = "start-bridge" ] || [ "$1" = "stop-bridge" ]; then
          cat <<'EOF'
        \(json)
        EOF
          exit 0
        fi
        exit 1
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    @MainActor
    func testFeatureViewModelsStayStableAcrossTabSelectionChanges() {
        let viewModel = ControlCenterViewModel()
        let dashboardViewModel = viewModel.dashboardViewModel
        let handoffsViewModel = viewModel.handoffsViewModel

        viewModel.selectedTab = .meetings
        viewModel.selectedTab = .privacy
        viewModel.selectedTab = .dashboard
        viewModel.selectedTab = .handoffs

        XCTAssertTrue(dashboardViewModel === viewModel.dashboardViewModel)
        XCTAssertTrue(handoffsViewModel === viewModel.handoffsViewModel)
    }

    @MainActor
    func testQuitApplicationDelegatesToLifecycleService() {
        let lifecycle = AppLifecycleSpy()
        let viewModel = ControlCenterViewModel(
            runner: BridgeCommandRunner(),
            appLifecycle: lifecycle
        )

        viewModel.quitApplication()

        XCTAssertEqual(lifecycle.quitCallCount, 1)
        XCTAssertEqual(lifecycle.relaunchCallCount, 0)
    }

    @MainActor
    func testRelaunchApplicationDelegatesToLifecycleService() {
        let lifecycle = AppLifecycleSpy()
        let viewModel = ControlCenterViewModel(
            runner: BridgeCommandRunner(),
            appLifecycle: lifecycle
        )

        viewModel.relaunchApplication()

        XCTAssertEqual(lifecycle.relaunchCallCount, 1)
        XCTAssertEqual(lifecycle.quitCallCount, 0)
    }

    @MainActor
    func testStartProductUpdatesStoppedSnapshotToRunning() throws {
        let scriptPath = try runnerScript(returning: """
        {
          "productState": "running",
          "trackingState": "active",
          "pauseUntil": null,
          "sensitiveMode": false,
          "queueDepth": 0,
          "daemonLaunchdState": "loaded",
          "watcherLaunchdState": "loaded"
        }
        """)
        let viewModel = ControlCenterViewModel(
            runner: BridgeCommandRunner(executablePath: scriptPath),
            appLifecycle: AppLifecycleSpy()
        )

        viewModel.startProduct()

        XCTAssertEqual(viewModel.snapshot.productState, .running)
        XCTAssertEqual(viewModel.productLifecycleActionTitle, "Shut Down ClawRelay")
    }

    @MainActor
    func testShutdownProductDelegatesToLifecycleQuitAfterStopBridge() throws {
        let lifecycle = AppLifecycleSpy()
        let scriptPath = try runnerScript(returning: """
        {
          "productState": "stopped",
          "trackingState": "active",
          "pauseUntil": null,
          "sensitiveMode": false,
          "queueDepth": 0,
          "daemonLaunchdState": "missing",
          "watcherLaunchdState": "missing"
        }
        """)
        let viewModel = ControlCenterViewModel(
            runner: BridgeCommandRunner(executablePath: scriptPath),
            appLifecycle: lifecycle
        )

        viewModel.shutdownProduct()

        XCTAssertEqual(lifecycle.quitCallCount, 1)
    }
}

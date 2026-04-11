import XCTest
@testable import OpenClawHelper

final class MenuBarViewModelTests: XCTestCase {
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

    private func failingActionRunnerScript(message: String = "boom") throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sh")
        let script = """
        #!/bin/bash
        if [ "$1" = "status" ]; then
          cat <<'EOF'
        {
          "productState": "running",
          "trackingState": "active",
          "pauseUntil": null,
          "sensitiveMode": false,
          "queueDepth": 0,
          "daemonLaunchdState": "loaded",
          "watcherLaunchdState": "loaded"
        }
        EOF
          exit 0
        fi
        cat <<'EOF' >&2
        {"status":"error","message":"\(message)"}
        EOF
        exit 1
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

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

    @MainActor
    func testStoppedSnapshotPrefersStartAction() {
        let snapshot = BridgeSnapshot(
            productState: .stopped,
            trackingState: .active,
            pauseUntil: nil,
            sensitiveMode: false,
            queueDepth: 0,
            daemonLaunchdState: "missing",
            watcherLaunchdState: "missing"
        )
        let model = MenuBarViewModel.preview(snapshot: snapshot)
        XCTAssertEqual(model.productLifecycleActionTitle, "Start ClawRelay")
    }

    @MainActor
    func testQuitApplicationDelegatesToLifecycleService() {
        let lifecycle = AppLifecycleSpy()
        let model = MenuBarViewModel(
            runner: BridgeCommandRunner(),
            appLifecycle: lifecycle
        )

        model.quitApplication()

        XCTAssertEqual(lifecycle.quitCallCount, 1)
        XCTAssertEqual(lifecycle.relaunchCallCount, 0)
    }

    @MainActor
    func testRelaunchApplicationDelegatesToLifecycleService() {
        let lifecycle = AppLifecycleSpy()
        let model = MenuBarViewModel(
            runner: BridgeCommandRunner(),
            appLifecycle: lifecycle
        )

        model.relaunchApplication()

        XCTAssertEqual(lifecycle.relaunchCallCount, 1)
        XCTAssertEqual(lifecycle.quitCallCount, 0)
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
        let model = MenuBarViewModel(
            runner: BridgeCommandRunner(executablePath: scriptPath),
            appLifecycle: lifecycle
        )

        model.shutdownProduct()

        XCTAssertEqual(lifecycle.quitCallCount, 1)
    }

    @MainActor
    func testPauseFailureSurfacesActionError() throws {
        let scriptPath = try failingActionRunnerScript(message: "pause failed")
        let model = MenuBarViewModel(
            runner: BridgeCommandRunner(executablePath: scriptPath),
            appLifecycle: AppLifecycleSpy()
        )

        model.pause(seconds: 900)

        XCTAssertEqual(model.actionError, "Pause failed: pause failed")
    }
}

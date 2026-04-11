import SwiftUI

enum ControlCenterTab: String, CaseIterable, Identifiable, Hashable {
    case dashboard, meetings, overview, permissions, privacy, handoffs, diagnostics
    var id: String { rawValue }
}

@MainActor
final class ControlCenterViewModel: ObservableObject {
    @Published var selectedTab: ControlCenterTab? = .dashboard
    @Published private(set) var snapshot: BridgeSnapshot = .placeholder
    @Published private(set) var recentErrors: [String] = []
    @Published private(set) var recentFswatchErrors: [String] = []
    @Published private(set) var configPaths: [(label: String, path: String)] = []
    @Published private(set) var permissions: [PermissionStatus] = []
    @Published var lastActionError: String?

    private let _runner: BridgeCommandRunner
    private let appLifecycle: AppLifecycleControlling
    private let permissionService = PermissionService()
    private var refreshTimer: RefreshTimer?

    let dashboardViewModel: DashboardViewModel
    let handoffsViewModel: HandoffsTabViewModel

    /// Public access for child view models (e.g. HandoffViewModel)
    var runner: BridgeCommandRunner { _runner }

    init(
        runner: BridgeCommandRunner = BridgeCommandRunner(),
        appLifecycle: AppLifecycleControlling = AppLifecycleService()
    ) {
        self._runner = runner
        self.appLifecycle = appLifecycle
        self.dashboardViewModel = DashboardViewModel(runner: runner)
        self.handoffsViewModel = HandoffsTabViewModel(runner: runner)
        loadConfigPaths()
        recheckPermissions()
    }

    func refresh() {
        snapshot = runner.fetchStatus()
        loadErrors()
        recheckPermissions()
    }

    func recheckPermissions() {
        permissions = permissionService.checkAll(snapshot: snapshot)
    }

    func startPolling() {
        refreshTimer = RefreshTimer(interval: 15.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refreshTimer?.start()
        refresh()
    }

    var productLifecycleActionTitle: String {
        snapshot.isProductStopped ? "Start ClawRelay" : "Shut Down ClawRelay"
    }

    func stopPolling() {
        refreshTimer?.stop()
        refreshTimer = nil
    }

    func restartDaemon() {
        lastActionError = nil
        do {
            try runner.runAction("restart-daemon")
        } catch {
            lastActionError = "Daemon restart failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func restartWatcher() {
        lastActionError = nil
        do {
            try runner.runAction("restart-watcher")
        } catch {
            lastActionError = "Watcher restart failed: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Privacy Controls

    func pause(seconds: Int) {
        lastActionError = nil
        do {
            try runner.runAction("pause", "\(seconds)")
        } catch {
            lastActionError = "Pause failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func pauseUntilTomorrow() {
        lastActionError = nil
        do {
            try runner.runAction("pause", "until-tomorrow")
        } catch {
            lastActionError = "Pause failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func pauseIndefinite() {
        lastActionError = nil
        do {
            try runner.runAction("pause", "indefinite")
        } catch {
            lastActionError = "Pause failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func resume() {
        lastActionError = nil
        do {
            try runner.runAction("resume")
        } catch {
            lastActionError = "Resume failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func setSensitiveMode(_ enabled: Bool) {
        lastActionError = nil
        do {
            try runner.runAction("sensitive", enabled ? "on" : "off")
        } catch {
            lastActionError = "Sensitive mode failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func purgeLocal() {
        lastActionError = nil
        do {
            try runner.runAction("purge-local")
        } catch {
            lastActionError = "Purge failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func quitApplication() {
        appLifecycle.quit()
    }

    func relaunchApplication() {
        appLifecycle.relaunch()
    }

    func startProduct() {
        lastActionError = nil
        do {
            snapshot = try runner.runSnapshotAction("start-bridge")
        } catch {
            lastActionError = "ClawRelay start failed: \(error.localizedDescription)"
            refresh()
        }
    }

    func shutdownProduct() {
        lastActionError = nil
        do {
            snapshot = try runner.runSnapshotAction("stop-bridge")
            stopPolling()
            appLifecycle.quit()
        } catch {
            lastActionError = "ClawRelay shutdown failed: \(error.localizedDescription)"
            refresh()
        }
    }

    private func loadErrors() {
        recentErrors = readLogTail("/tmp/context-bridge-error.log", lines: 10)
        recentFswatchErrors = readLogTail("/tmp/context-bridge-fswatch-error.log", lines: 10)
    }

    private func readLogTail(_ path: String, lines: Int) -> [String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let allLines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return Array(allLines.suffix(lines))
    }

    private func loadConfigPaths() {
        let home = NSHomeDirectory()
        configPaths = [
            ("Config directory", "\(home)/.context-bridge"),
            ("Server URL", "\(home)/.context-bridge/server-url"),
            ("Runtime scripts", "\(home)/.context-bridge/bin"),
            ("Local queue DB", "\(home)/.context-bridge/local.db"),
            ("Daemon log", "/tmp/context-bridge.log"),
            ("Daemon errors", "/tmp/context-bridge-error.log"),
            ("Watcher log", "/tmp/context-bridge-fswatch.log"),
            ("Watcher errors", "/tmp/context-bridge-fswatch-error.log"),
            ("WhatsApp log", "/tmp/claw-whatsapp.log"),
            ("WhatsApp errors", "/tmp/claw-whatsapp-error.log"),
            ("WhatsApp health", "\(home)/.context-bridge/whatsapp-health.json"),
            ("Privacy rules", "\(home)/.context-bridge/privacy-rules.json"),
        ]
    }
}

// MARK: - Preview / Test Support

extension ControlCenterViewModel {
    static func preview(snapshot: BridgeSnapshot) -> ControlCenterViewModel {
        let vm = ControlCenterViewModel()
        vm.snapshot = snapshot
        return vm
    }
}

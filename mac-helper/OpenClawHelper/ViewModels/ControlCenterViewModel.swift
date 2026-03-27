import SwiftUI

enum ControlCenterTab: String, CaseIterable, Identifiable {
    case overview, permissions, privacy, diagnostics
    var id: String { rawValue }
}

@MainActor
final class ControlCenterViewModel: ObservableObject {
    @Published var selectedTab: ControlCenterTab = .overview
    @Published private(set) var snapshot: BridgeSnapshot = .placeholder
    @Published private(set) var recentErrors: [String] = []
    @Published private(set) var recentFswatchErrors: [String] = []
    @Published private(set) var configPaths: [(label: String, path: String)] = []
    @Published var lastActionError: String?

    private let runner: BridgeCommandRunner
    private var refreshTimer: RefreshTimer?

    init(runner: BridgeCommandRunner = BridgeCommandRunner()) {
        self.runner = runner
        loadConfigPaths()
    }

    func refresh() {
        snapshot = runner.fetchStatus()
        loadErrors()
    }

    func startPolling() {
        refreshTimer = RefreshTimer(interval: 5.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refreshTimer?.start()
        refresh()
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

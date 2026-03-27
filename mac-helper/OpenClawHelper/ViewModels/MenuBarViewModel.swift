import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published private(set) var snapshot: BridgeSnapshot = .placeholder
    private let runner: BridgeCommandRunner
    private var refreshTimer: RefreshTimer?

    init(runner: BridgeCommandRunner = BridgeCommandRunner()) {
        self.runner = runner
    }

    var primaryActionTitle: String {
        snapshot.trackingState == .paused ? "Resume" : "Pause 15m"
    }

    func refresh() {
        snapshot = runner.fetchStatus()
    }

    func pause(seconds: Int) {
        try? runner.runAction("pause", "\(seconds)")
        refresh()
    }

    func pauseUntilTomorrow() {
        try? runner.runAction("pause", "until-tomorrow")
        refresh()
    }

    func resume() {
        try? runner.runAction("resume")
        refresh()
    }

    func setSensitiveMode(_ enabled: Bool) {
        try? runner.runAction("sensitive", enabled ? "on" : "off")
        refresh()
    }

    func startPolling() {
        refreshTimer = RefreshTimer(interval: 5.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refreshTimer?.start()
        refresh() // immediate first fetch
    }

    func stopPolling() {
        refreshTimer?.stop()
        refreshTimer = nil
    }
}

// MARK: - Preview / Test Support

extension MenuBarViewModel {
    static func preview(snapshot: BridgeSnapshot) -> MenuBarViewModel {
        let vm = MenuBarViewModel()
        vm.snapshot = snapshot
        return vm
    }
}

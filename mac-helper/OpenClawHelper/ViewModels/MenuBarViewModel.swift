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

    @Published var handoffProject: String = UserDefaults.standard.string(forKey: "lastHandoffProject") ?? ""
    @Published var handoffTask: String = ""
    @Published var handoffSent: Bool = false

    static let portfolioProjects = ["prescrivia", "leverwork", "jsvhq", "sonopeace", "openclaw"]

    func sendQuickHandoff() {
        let project = handoffProject.isEmpty ? "general" : handoffProject
        do {
            try runner.runAction("queue-handoff", project, handoffTask, "", "normal")
            UserDefaults.standard.set(handoffProject, forKey: "lastHandoffProject")
            handoffTask = ""
            handoffSent = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.handoffSent = false
            }
        } catch {
            // Silently fail for menu bar quick actions
        }
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

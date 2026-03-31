import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published private(set) var snapshot: BridgeSnapshot = .placeholder
    @Published var dashboard: DashboardData?
    @Published private(set) var whatsAppStatus: String = "Not installed"
    @Published private(set) var whatsAppContacts: [WhatsAppStatusService.WhitelistContact] = []
    private let runner: BridgeCommandRunner
    private let waService = WhatsAppStatusService()
    private var refreshTimer: RefreshTimer?

    init(runner: BridgeCommandRunner = BridgeCommandRunner()) {
        self.runner = runner
    }

    var primaryActionTitle: String {
        snapshot.trackingState == .paused ? "Resume" : "Pause 15m"
    }

    func refresh() {
        snapshot = runner.fetchStatus()
        fetchDashboard()
        refreshWhatsApp()
    }

    private func refreshWhatsApp() {
        whatsAppStatus = waService.displayStatus
        whatsAppContacts = waService.fetchWhitelistContacts()
    }

    func relinkWhatsApp() {
        let command = "\(NSHomeDirectory())/.context-bridge/bin/claw-whatsapp --auth"
        let script = NSAppleScript(source: "tell application \"Terminal\" to do script \"\(command)\"")
        script?.executeAndReturnError(nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    func addWhatsAppContact() {
        let command = "\(NSHomeDirectory())/.context-bridge/bin/claw-whatsapp --setup"
        let script = NSAppleScript(source: "tell application \"Terminal\" to do script \"\(command)\"")
        script?.executeAndReturnError(nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    func fetchDashboard() {
        let capturedRunner = runner
        Task.detached {
            do {
                let raw = try capturedRunner.runActionWithOutput("dashboard")
                let decoded = try JSONDecoder().decode(DashboardData.self, from: raw)
                await MainActor.run { [weak self] in
                    self?.dashboard = decoded
                }
            } catch {
                // Silently fail — popover summary is best-effort
            }
        }
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

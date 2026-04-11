import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published private(set) var snapshot: BridgeSnapshot = .placeholder
    @Published var dashboard: DashboardData?
    @Published private(set) var whatsAppStatus: String = "Not installed"
    @Published private(set) var whatsAppContacts: [WhatsAppStatusService.WhitelistContact] = []
    @Published var portfolioProjects: [String] = []
    @Published var actionError: String?
    private let runner: BridgeCommandRunner
    private let appLifecycle: AppLifecycleControlling
    private let waService = WhatsAppStatusService()
    private var refreshTimer: RefreshTimer?

    init(
        runner: BridgeCommandRunner = BridgeCommandRunner(),
        appLifecycle: AppLifecycleControlling = AppLifecycleService()
    ) {
        self.runner = runner
        self.appLifecycle = appLifecycle
    }

    var primaryActionTitle: String {
        snapshot.trackingState == .paused ? "Resume" : "Pause 15m"
    }

    var productLifecycleActionTitle: String {
        snapshot.isProductStopped ? "Start ClawRelay" : "Shut Down ClawRelay"
    }

    func refresh() {
        snapshot = runner.fetchStatus()
        fetchDashboard()
        fetchPortfolioProjects()
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

    func fetchPortfolioProjects() {
        let capturedRunner = runner
        Task.detached {
            do {
                let raw = try capturedRunner.runActionWithOutput("projects")
                let decoded = try JSONDecoder().decode(ProjectsResponse.self, from: raw)
                await MainActor.run { [weak self] in
                    self?.portfolioProjects = decoded.projects.sorted()
                }
            } catch {
                // Silently fail — keep current list
            }
        }
    }

    func pause(seconds: Int) {
        actionError = nil
        do {
            try runner.runAction("pause", "\(seconds)")
        } catch {
            actionError = "Pause failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func pauseUntilTomorrow() {
        actionError = nil
        do {
            try runner.runAction("pause", "until-tomorrow")
        } catch {
            actionError = "Pause failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func resume() {
        actionError = nil
        do {
            try runner.runAction("resume")
        } catch {
            actionError = "Resume failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func setSensitiveMode(_ enabled: Bool) {
        actionError = nil
        do {
            try runner.runAction("sensitive", enabled ? "on" : "off")
        } catch {
            actionError = "Sensitive mode failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func startPolling() {
        refreshTimer = RefreshTimer(interval: 15.0) { [weak self] in
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
    @Published var handoffSending: Bool = false
    @Published var handoffError: String?

    func sendQuickHandoff() {
        let project = handoffProject.isEmpty ? "general" : handoffProject
        let task = handoffTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        handoffSent = false
        handoffError = nil
        handoffSending = true

        let capturedRunner = runner
        Task.detached {
            do {
                _ = try capturedRunner.runActionWithOutput("submit-handoff", project, task, "", "normal")
                await MainActor.run { [weak self] in
                    UserDefaults.standard.set(project, forKey: "lastHandoffProject")
                    self?.handoffTask = ""
                    self?.handoffSending = false
                    self?.handoffSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.handoffSent = false
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.handoffSending = false
                    self?.handoffError = "Handoff failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func quitApplication() {
        appLifecycle.quit()
    }

    func relaunchApplication() {
        appLifecycle.relaunch()
    }

    func startProduct() {
        actionError = nil
        do {
            snapshot = try runner.runSnapshotAction("start-bridge")
        } catch {
            actionError = "ClawRelay start failed: \(error.localizedDescription)"
            refresh()
        }
    }

    func shutdownProduct() {
        actionError = nil
        do {
            snapshot = try runner.runSnapshotAction("stop-bridge")
            stopPolling()
            appLifecycle.quit()
        } catch {
            actionError = "ClawRelay shutdown failed: \(error.localizedDescription)"
            refresh()
        }
    }
}

private struct ProjectsResponse: Codable {
    let projects: [String]
}

// MARK: - Preview / Test Support

extension MenuBarViewModel {
    static func preview(snapshot: BridgeSnapshot) -> MenuBarViewModel {
        let vm = MenuBarViewModel()
        vm.snapshot = snapshot
        return vm
    }
}

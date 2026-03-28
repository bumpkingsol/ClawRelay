import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var data: DashboardData?
    @Published var lastError: String?

    private let runner: BridgeCommandRunner
    private var refreshTimer: RefreshTimer?

    init(runner: BridgeCommandRunner) {
        self.runner = runner
    }

    func refreshDashboard() {
        let capturedRunner = runner
        Task.detached {
            do {
                let raw = try capturedRunner.runActionWithOutput("dashboard")
                let decoded = try JSONDecoder().decode(DashboardData.self, from: raw)
                await MainActor.run { [weak self] in
                    self?.data = decoded
                    self?.lastError = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    // Only show error if we have no data at all
                    if self?.data == nil {
                        self?.lastError = "Dashboard unavailable"
                    }
                }
            }
        }
    }

    func startPolling() {
        refreshTimer = RefreshTimer(interval: 120.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshDashboard()
            }
        }
        refreshTimer?.start()
        refreshDashboard()
    }

    func stopPolling() {
        refreshTimer?.stop()
        refreshTimer = nil
    }
}

import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var data: DashboardData?
    @Published var lastError: String?
    @Published var historyDays: Int = 7

    private let runner: BridgeCommandRunner
    private var refreshTimer: RefreshTimer?
    private var previousHandoffStatuses: [Int: String] = [:]

    init(runner: BridgeCommandRunner) {
        self.runner = runner
    }

    func refreshDashboard() {
        let capturedRunner = runner
        Task.detached {
            do {
                let days = await MainActor.run { [weak self] in self?.historyDays ?? 7 }
                let raw = try capturedRunner.runActionWithOutput("dashboard", "\(days)")
                let decoded = try JSONDecoder().decode(DashboardData.self, from: raw)
                await MainActor.run { [weak self] in
                    self?.data = decoded
                    self?.lastError = nil
                    self?.checkForNotifications(decoded)
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

    private func checkForNotifications(_ newData: DashboardData) {
        // 1. Handoff status changes
        for handoff in newData.handoffs {
            let prev = previousHandoffStatuses[handoff.id]
            if let prev = prev, prev != handoff.status,
               (handoff.status == "in-progress" || handoff.status == "done") {
                let verb = handoff.status == "done" ? "completed" : "started"
                NotificationService.shared.send(
                    title: "Agent \(verb): \(handoff.task)",
                    body: handoff.project.capitalized
                )
            }
            previousHandoffStatuses[handoff.id] = handoff.status
        }

        // 2. Neglect alerts (once daily per project, skip 999 = no data)
        let todayStr = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        for item in newData.neglected where item.days >= 7 && item.days < 999 {
            let key = "neglect-notified-\(item.project)"
            let lastNotified = UserDefaults.standard.string(forKey: key)
            if lastNotified != todayStr {
                NotificationService.shared.send(
                    title: "\(item.project.capitalized) needs attention",
                    body: "\(item.days) days since last activity"
                )
                UserDefaults.standard.set(todayStr, forKey: key)
            }
        }

        // 3. Agent questions
        if let questions = newData.jcQuestions {
            for q in questions {
                NotificationService.shared.send(
                    title: "Agent asks about \(q.project ?? "general")",
                    body: q.question
                )
                let capturedRunner = runner
                let qid = q.id
                Task.detached {
                    try? capturedRunner.runAction("mark-question-seen", "\(qid)")
                }
            }
        }
    }
}

import SwiftUI

@MainActor
final class HandoffsTabViewModel: ObservableObject {
    @Published var draft = HandoffDraft(project: UserDefaults.standard.string(forKey: "lastHandoffProject") ?? "")
    @Published var handoffs: [Handoff] = []
    @Published var isSubmitting = false
    @Published var sentConfirmation = false
    @Published var lastError: String?

    private let runner: BridgeCommandRunner
    private var refreshTimer: RefreshTimer?

    static let portfolioProjects = ["project-gamma", "project-alpha", "project-beta", "project-delta", "openclaw"]

    init(runner: BridgeCommandRunner) {
        self.runner = runner
    }

    func submit() {
        guard draft.isValid else { return }
        isSubmitting = true
        lastError = nil
        let project = draft.projectOrDefault
        let task = draft.task
        let message = draft.message
        let priority = draft.priority
        let capturedRunner = runner
        Task.detached {
            do {
                try capturedRunner.runAction("queue-handoff", project, task, message, priority)
                await MainActor.run { [weak self] in
                    self?.draft = HandoffDraft()
                    self?.isSubmitting = false
                    self?.sentConfirmation = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.sentConfirmation = false
                    }
                    self?.refreshHandoffs()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "Send failed: \(error.localizedDescription)"
                    self?.isSubmitting = false
                }
            }
        }
        UserDefaults.standard.set(draft.project, forKey: "lastHandoffProject")
    }

    func refreshHandoffs() {
        let capturedRunner = runner
        Task.detached {
            do {
                let data = try capturedRunner.runActionWithOutput("list-handoffs")
                let decoded = try JSONDecoder().decode([Handoff].self, from: data)
                await MainActor.run { [weak self] in
                    self?.handoffs = decoded
                }
            } catch {
                // Silently keep existing list on failure
            }
        }
    }

    func startPolling() {
        refreshTimer = RefreshTimer(interval: 30.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshHandoffs()
            }
        }
        refreshTimer?.start()
        refreshHandoffs()
    }

    func stopPolling() {
        refreshTimer?.stop()
        refreshTimer = nil
    }
}

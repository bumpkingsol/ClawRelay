import SwiftUI

@MainActor
final class HandoffViewModel: ObservableObject {
    @Published var draft = HandoffDraft()
    @Published var isSubmitting = false
    @Published var lastError: String?
    @Published var didSubmit = false

    private let runner: BridgeCommandRunner

    init(runner: BridgeCommandRunner = BridgeCommandRunner()) {
        self.runner = runner
    }

    func submit() {
        guard draft.isValid else { return }
        isSubmitting = true
        lastError = nil
        do {
            try runner.runAction("queue-handoff", draft.project, draft.task, draft.message)
            didSubmit = true
            draft = HandoffDraft()
        } catch {
            lastError = "Failed to queue handoff: \(error.localizedDescription)"
        }
        isSubmitting = false
    }

    func reset() {
        draft = HandoffDraft()
        lastError = nil
        didSubmit = false
    }
}

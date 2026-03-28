import SwiftUI

struct HandoffSheetView: View {
    @ObservedObject var viewModel: HandoffViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Queue Handoff")
                .font(.headline)

            TextField("Project", text: $viewModel.draft.project)
                .textFieldStyle(.roundedBorder)
            TextField("Task", text: $viewModel.draft.task)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $viewModel.draft.message)
                .frame(height: 80)
                .border(Color.secondary.opacity(0.3))

            if let error = viewModel.lastError {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            if viewModel.didSubmit {
                Label("Handoff queued", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Send") { viewModel.submit() }
                    .disabled(!viewModel.draft.isValid || viewModel.isSubmitting)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

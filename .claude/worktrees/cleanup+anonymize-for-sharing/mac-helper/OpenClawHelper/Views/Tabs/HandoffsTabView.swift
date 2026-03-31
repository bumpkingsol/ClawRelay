import SwiftUI

struct HandoffsTabView: View {
    @StateObject var viewModel: HandoffsTabViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                composeSection
                historySection
            }
            .padding()
        }
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    // MARK: - Compose

    private var composeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hand Off to Agent")
                .font(.title2)

            HStack {
                Text("Project")
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                ComboBox(
                    text: $viewModel.draft.project,
                    options: HandoffsTabViewModel.portfolioProjects
                )
            }

            HStack {
                Text("Task")
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("What should the agent do?", text: $viewModel.draft.task)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top) {
                Text("Details")
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                TextEditor(text: $viewModel.draft.message)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            HStack {
                Text("Priority")
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Picker("", selection: $viewModel.draft.priority) {
                    Text("Normal").tag("normal")
                    Text("High").tag("high")
                    Text("Urgent").tag("urgent")
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Spacer()

                if viewModel.sentConfirmation {
                    Text("Sent")
                        .foregroundStyle(.green)
                        .font(.callout)
                }

                Button("Send") {
                    viewModel.submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.draft.isValid || viewModel.isSubmitting)
            }

            if let error = viewModel.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding()
        .glassCard()
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Handoff History")
                .font(.title2)

            if viewModel.handoffs.isEmpty {
                Text("No handoffs yet")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(viewModel.handoffs) { handoff in
                    handoffRow(handoff)
                }
            }
        }
        .padding()
        .glassCard()
    }

    private func handoffRow(_ handoff: Handoff) -> some View {
        DisclosureGroup {
            if !handoff.message.isEmpty {
                Text(handoff.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(handoff.project)
                        .font(.headline)
                    Text(handoff.task)
                        .font(.callout)
                        .lineLimit(1)
                }

                Spacer()

                if handoff.priority != "normal" {
                    priorityBadge(handoff.priority)
                }

                statusBadge(handoff.status)

                Text(relativeTime(handoff.createdAt))
                    .font(DarkUtilityGlass.monoCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private func priorityBadge(_ priority: String) -> some View {
        Text(priority.capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                priority == "urgent" ? Color.red.opacity(0.3) : Color.orange.opacity(0.3),
                in: Capsule()
            )
            .foregroundStyle(priority == "urgent" ? .red : .orange)
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status.replacingOccurrences(of: "-", with: " ").capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(status).opacity(0.2), in: Capsule())
            .foregroundStyle(statusColor(status))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "done": return .green
        case "in-progress": return .orange
        default: return .secondary
        }
    }

    private func relativeTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString)
                ?? ISO8601DateFormatter().date(from: isoString) else {
            return String(isoString.prefix(16)).replacingOccurrences(of: "T", with: " ")
        }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 172800 { return "yesterday" }
        return "\(Int(interval / 86400)) days ago"
    }
}

// MARK: - ComboBox (dropdown + freeform)

struct ComboBox: View {
    @Binding var text: String
    let options: [String]

    var body: some View {
        HStack(spacing: 4) {
            TextField("Project", text: $text)
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option.capitalized) {
                        text = option
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
        }
    }
}

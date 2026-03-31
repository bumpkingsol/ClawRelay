import SwiftUI

struct MeetingStatusView: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: viewModel.state.systemImage)
                    .font(.title3)
                    .foregroundStyle(stateColor)
                    .symbolEffect(.pulse, isActive: viewModel.state == .recording)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting: \(viewModel.state.displayLabel)")
                        .font(DarkUtilityGlass.compactBody)

                    if viewModel.isActive {
                        HStack(spacing: 4) {
                            Text(viewModel.formattedElapsed)
                                .font(DarkUtilityGlass.monoCaption)
                                .foregroundStyle(.secondary)

                            if let app = viewModel.sessionManager.sessionInfo?.app {
                                Text("(\(app))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if viewModel.firedCardCount > 0 {
                                Text("\(viewModel.firedCardCount) cards")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.blue.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }

                Spacer()

                meetingActions
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverCardRadius)
                .fill(DarkUtilityGlass.cardBackground)
                .strokeBorder(DarkUtilityGlass.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var meetingActions: some View {
        switch viewModel.state {
        case .idle:
            Button(action: { viewModel.startMeeting() }) {
                Label("Start", systemImage: "mic.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.green)

        case .awaitingConsent:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Consent Pending")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

        case .preparing:
            ProgressView()
                .controlSize(.small)

        case .recording:
            HStack(spacing: 6) {
                Button(action: { viewModel.toggleSidebar() }) {
                    Image(systemName: "sidebar.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button(action: { viewModel.stopMeeting() }) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

        case .finalizing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Button(action: { viewModel.cancelFinalization() }) {
                    Text("Cancel")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var stateColor: Color {
        switch viewModel.state {
        case .idle:             return .secondary
        case .awaitingConsent:  return .orange
        case .preparing:        return .orange
        case .recording:  return .red
        case .finalizing: return .blue
        }
    }
}

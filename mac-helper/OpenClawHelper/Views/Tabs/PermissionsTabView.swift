import SwiftUI

struct PermissionsTabView: View {
    @ObservedObject var viewModel: ControlCenterViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("macOS Permissions")
                    .font(.title2)
                    .padding(.bottom, 4)

                Text("The Context Bridge daemon needs these permissions to capture your activity. Grant them to the terminal app that runs the daemon (usually Terminal).")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(viewModel.permissions, id: \.kind) { status in
                    permissionRow(status)
                }
            }
            .padding()
        }
    }

    private func permissionRow(_ status: PermissionStatus) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: stateIcon(status.state))
                        .foregroundStyle(stateColor(status.state))
                    Text(kindLabel(status.kind))
                        .font(.headline)
                    Spacer()
                    stateLabel(status.state)
                }
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Settings") {
                        SettingsDeepLinkService.open(for: status.kind)
                    }
                    Button("Check Again") {
                        viewModel.recheckPermissions()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Helpers

    private func stateIcon(_ state: PermissionStatus.State) -> String {
        switch state {
        case .granted: return "checkmark.circle.fill"
        case .missing: return "xmark.octagon.fill"
        case .needsReview: return "exclamationmark.triangle.fill"
        }
    }

    private func stateColor(_ state: PermissionStatus.State) -> Color {
        switch state {
        case .granted: return .green
        case .missing: return .red
        case .needsReview: return .orange
        }
    }

    private func kindLabel(_ kind: PermissionStatus.Kind) -> String {
        switch kind {
        case .accessibility: return "Accessibility"
        case .automation: return "Automation"
        case .fullDiskAccess: return "Full Disk Access"
        }
    }

    @ViewBuilder
    private func stateLabel(_ state: PermissionStatus.State) -> some View {
        switch state {
        case .granted:
            Text("Granted")
                .font(.caption)
                .foregroundStyle(.green)
        case .missing:
            Text("Missing")
                .font(.caption)
                .foregroundStyle(.red)
        case .needsReview:
            Text("Needs Review")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

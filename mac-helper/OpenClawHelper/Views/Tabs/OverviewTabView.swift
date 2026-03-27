import SwiftUI

struct OverviewTabView: View {
    @ObservedObject var viewModel: ControlCenterViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Status section
                GroupBox("Current State") {
                    HStack(spacing: 20) {
                        stateCard(
                            "Tracking",
                            value: viewModel.snapshot.trackingState.rawValue.capitalized,
                            icon: viewModel.snapshot.trackingState.menuBarSymbol,
                            warn: viewModel.snapshot.trackingState == .needsAttention
                        )
                        stateCard(
                            "Queue",
                            value: "\(viewModel.snapshot.queueDepth) pending",
                            icon: "tray.full",
                            warn: viewModel.snapshot.queueDepth > 10
                        )
                    }
                }

                // Services section
                GroupBox("Services") {
                    HStack(spacing: 20) {
                        serviceRow("Daemon", state: viewModel.snapshot.daemonLaunchdState) {
                            viewModel.restartDaemon()
                        }
                        serviceRow("File Watcher", state: viewModel.snapshot.watcherLaunchdState) {
                            viewModel.restartWatcher()
                        }
                    }
                }

                // Sensitive mode
                if viewModel.snapshot.sensitiveMode {
                    GroupBox {
                        Label("Sensitive Mode is active - capture is reduced", systemImage: "hand.raised.fill")
                    }
                }

                // Pause info
                if let pauseUntil = viewModel.snapshot.pauseUntil {
                    GroupBox {
                        Label(
                            "Paused: \(pauseUntil == "indefinite" ? "indefinitely" : "until \(pauseUntil)")",
                            systemImage: "pause.circle.fill"
                        )
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Helper Views

    private func stateCard(_ title: String, value: String, icon: String, warn: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(warn ? .orange : .green)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(warn ? .orange : .primary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func serviceRow(_ name: String, state: String, restart: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                Text(state)
                    .font(.caption)
                    .foregroundStyle(state == "loaded" ? .green : .orange)
            }
            Spacer()
            Button("Restart") {
                restart()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

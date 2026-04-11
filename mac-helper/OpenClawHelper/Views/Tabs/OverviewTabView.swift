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
                            "ClawRelay",
                            value: viewModel.snapshot.isProductStopped ? "Stopped" : "Running",
                            icon: viewModel.snapshot.isProductStopped ? "power.circle" : viewModel.snapshot.trackingState.menuBarSymbol,
                            warn: viewModel.snapshot.isProductStopped || viewModel.snapshot.trackingState == .needsAttention
                        )
                        stateCard(
                            "Queue",
                            value: "\(viewModel.snapshot.queueDepth) pending",
                            icon: "tray.full",
                            warn: viewModel.snapshot.queueDepth > 10
                        )
                    }
                }
                .groupBoxStyle(.automatic)

                // Services section
                GroupBox("Services") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 20) {
                            serviceRow("Daemon", state: viewModel.snapshot.daemonLaunchdState) {
                                viewModel.restartDaemon()
                            }
                            serviceRow("File Watcher", state: viewModel.snapshot.watcherLaunchdState) {
                                viewModel.restartWatcher()
                            }
                        }

                        HStack {
                            Text(viewModel.snapshot.isProductStopped ? "Background capture is off." : "Background capture is running.")
                                .font(DarkUtilityGlass.compactBody)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(viewModel.productLifecycleActionTitle) {
                                if viewModel.snapshot.isProductStopped {
                                    viewModel.startProduct()
                                } else {
                                    viewModel.shutdownProduct()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                if let diagnostic = viewModel.snapshot.chromeAutomationDiagnostic,
                   diagnostic.status == .unavailable {
                    GroupBox("Capture Warning") {
                        Label(diagnostic.detail, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if let diagnostic = viewModel.snapshot.meetingBinaryDiagnostic,
                   diagnostic.status == .missing || diagnostic.status == .unlaunchable {
                    GroupBox("Meeting Worker") {
                        Label(diagnostic.detail, systemImage: "mic.badge.xmark")
                            .foregroundStyle(.orange)
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

                if viewModel.snapshot.isProductStopped {
                    GroupBox {
                        Label("Background capture is off.", systemImage: "power.circle.fill")
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
                .font(DarkUtilityGlass.compactBody)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(warn ? .orange : .primary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .glassCard()
    }

    private func serviceRow(_ name: String, state: String, restart: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                Text(state)
                    .font(DarkUtilityGlass.monoCaption)
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
        .glassCard()
    }
}

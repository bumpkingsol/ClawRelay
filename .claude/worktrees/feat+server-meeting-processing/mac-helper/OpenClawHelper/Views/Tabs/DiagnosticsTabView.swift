import SwiftUI

struct DiagnosticsTabView: View {
    @ObservedObject var viewModel: ControlCenterViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Error banner
                if let error = viewModel.lastActionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .padding()
                        .glassCard()
                }

                // Recent errors
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Daemon Errors")
                        .font(.headline)
                    if viewModel.recentErrors.isEmpty {
                        Text("No recent errors").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(viewModel.recentErrors.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(DarkUtilityGlass.monoCaption)
                            }
                        }
                    }
                }
                .padding()
                .glassCard()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Watcher Errors")
                        .font(.headline)
                    if viewModel.recentFswatchErrors.isEmpty {
                        Text("No recent errors").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(viewModel.recentFswatchErrors.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(DarkUtilityGlass.monoCaption)
                            }
                        }
                    }
                }
                .padding()
                .glassCard()

                // Config paths
                VStack(alignment: .leading, spacing: 8) {
                    Text("Configuration Paths")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.configPaths, id: \.label) { item in
                            HStack {
                                Text(item.label)
                                    .font(DarkUtilityGlass.compactBody)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .trailing)
                                Text(item.path)
                                    .font(DarkUtilityGlass.monoCaption)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                }
                .padding()
                .glassCard()

                // Repair actions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Repair Actions")
                        .font(.headline)
                    HStack(spacing: 12) {
                        Button("Restart Daemon") { viewModel.restartDaemon() }
                        Button("Restart Watcher") { viewModel.restartWatcher() }
                    }
                }
                .padding()
                .glassCard()
            }
            .padding()
        }
    }
}

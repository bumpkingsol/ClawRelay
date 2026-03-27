import SwiftUI

struct DiagnosticsTabView: View {
    @ObservedObject var viewModel: ControlCenterViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Error banner
                if let error = viewModel.lastActionError {
                    GroupBox {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                // Recent errors
                GroupBox("Recent Daemon Errors") {
                    if viewModel.recentErrors.isEmpty {
                        Text("No recent errors").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(viewModel.recentErrors.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                }

                GroupBox("Recent Watcher Errors") {
                    if viewModel.recentFswatchErrors.isEmpty {
                        Text("No recent errors").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(viewModel.recentFswatchErrors.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                }

                // Config paths
                GroupBox("Configuration Paths") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.configPaths, id: \.label) { item in
                            HStack {
                                Text(item.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .trailing)
                                Text(item.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                }

                // Repair actions
                GroupBox("Repair Actions") {
                    HStack(spacing: 12) {
                        Button("Restart Daemon") { viewModel.restartDaemon() }
                        Button("Restart Watcher") { viewModel.restartWatcher() }
                    }
                }
            }
            .padding()
        }
    }
}

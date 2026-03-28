import SwiftUI

struct PrivacyTabView: View {
    @ObservedObject var viewModel: ControlCenterViewModel
    @State private var showHandoffSheet = false
    @State private var showPurgeConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // What Pause and Sensitive mean
                VStack(alignment: .leading, spacing: 12) {
                    Text("Privacy Controls")
                        .font(.headline)

                    Label {
                        VStack(alignment: .leading) {
                            Text("Pause").font(.headline)
                            Text("Stops all local context generation. No shell commands, file changes, or window info is captured.")
                                .font(DarkUtilityGlass.compactBody).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                    }

                    Label {
                        VStack(alignment: .leading) {
                            Text("Sensitive Mode").font(.headline)
                            Text("Keeps the system operational but reduces capture to minimal heartbeat payloads. Shell commands and git commits still flow.")
                                .font(DarkUtilityGlass.compactBody).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.purple)
                    }
                }
                .padding()
                .glassCard()

                // Pause presets
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pause Presets")
                        .font(.headline)
                    HStack(spacing: 12) {
                        Button("15 min") { viewModel.pause(seconds: 900) }
                        Button("1 hour") { viewModel.pause(seconds: 3600) }
                        Button("Until Tomorrow") { viewModel.pauseUntilTomorrow() }
                        Button("Indefinite") { viewModel.pauseIndefinite() }
                        if viewModel.snapshot.trackingState == .paused {
                            Button("Resume") { viewModel.resume() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding()
                .glassCard()

                // Sensitive mode
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sensitive Mode")
                        .font(.headline)
                    Toggle("Enable Sensitive Mode", isOn: Binding(
                        get: { viewModel.snapshot.sensitiveMode },
                        set: { viewModel.setSensitiveMode($0) }
                    ))
                }
                .padding()
                .glassCard()

                // Handoff
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Handoff")
                        .font(.headline)
                    Text("Send a task handoff to JC")
                        .font(DarkUtilityGlass.compactBody).foregroundStyle(.secondary)
                    Button("Compose Handoff...") {
                        showHandoffSheet = true
                    }
                }
                .padding()
                .glassCard()

                // Local purge
                VStack(alignment: .leading, spacing: 8) {
                    Text("Danger Zone")
                        .font(.headline)
                    Text("Delete all local context data including queue, logs, and pause state.")
                        .font(DarkUtilityGlass.compactBody).foregroundStyle(.secondary)
                    Button("Purge Local Data", role: .destructive) {
                        showPurgeConfirmation = true
                    }
                }
                .padding()
                .glassCard()
            }
            .padding()
        }
        .sheet(isPresented: $showHandoffSheet) {
            HandoffSheetView(viewModel: HandoffViewModel(runner: viewModel.runner))
        }
        .confirmationDialog("Purge Local Data?", isPresented: $showPurgeConfirmation) {
            Button("Purge", role: .destructive) { viewModel.purgeLocal() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete the local queue, pause state, and all buffered context. This cannot be undone.")
        }
    }
}

import SwiftUI

struct QuickActionsGrid: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if viewModel.snapshot.trackingState == .paused {
                    actionButton("Resume", systemImage: "play.fill") {
                        viewModel.resume()
                    }
                } else {
                    actionButton("Pause 15m", systemImage: "pause.fill") {
                        viewModel.pause(seconds: 900)
                    }
                }
                actionButton("Pause 1h", systemImage: "pause.circle") {
                    viewModel.pause(seconds: 3600)
                }
                actionButton("Until Tomorrow", systemImage: "moon.fill") {
                    viewModel.pauseUntilTomorrow()
                }
            }
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { viewModel.snapshot.sensitiveMode },
                    set: { viewModel.setSensitiveMode($0) }
                )) {
                    Label("Sensitive", systemImage: "hand.raised.fill")
                        .font(.caption)
                }
                .toggleStyle(.button)
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

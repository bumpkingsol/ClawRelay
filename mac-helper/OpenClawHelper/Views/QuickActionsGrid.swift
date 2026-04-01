import SwiftUI

struct QuickActionsGrid: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        VStack(spacing: 12) {
            if viewModel.snapshot.isProductStopped {
                startButton
            } else {
                pauseControl
                sensitiveToggle
            }
        }
    }

    private var startButton: some View {
        Button(action: { viewModel.startProduct() }) {
            HStack(spacing: 6) {
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 12))
                Text("Start ClawRelay")
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(DarkUtilityGlass.activeGreen)
        .popoverGlassSurface(
            tint: DarkUtilityGlass.activeGreen.opacity(0.30),
            fallbackFill: DarkUtilityGlass.activeGreen.opacity(0.10),
            fallbackStroke: DarkUtilityGlass.activeGreen.opacity(0.20),
            interactive: true
        )
    }

    @ViewBuilder
    private var pauseControl: some View {
        if viewModel.snapshot.trackingState == .paused {
            // Resume button
            Button(action: { viewModel.resume() }) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                    Text("Resume Tracking")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DarkUtilityGlass.activeGreen)
            .popoverGlassSurface(
                tint: DarkUtilityGlass.activeGreen.opacity(0.30),
                fallbackFill: DarkUtilityGlass.activeGreen.opacity(0.10),
                fallbackStroke: DarkUtilityGlass.activeGreen.opacity(0.20),
                interactive: true
            )
        } else {
            // Segmented pause control
            HStack(spacing: 0) {
                pauseSegment("Pause 15m") { viewModel.pause(seconds: 900) }
                pauseSegment("Pause 1h") { viewModel.pause(seconds: 3600) }
                pauseSegment("Until Tmrw") { viewModel.pauseUntilTomorrow() }
            }
            .padding(3)
            .popoverGlassSurface(interactive: true)
        }
    }

    private func pauseSegment(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverSegmentRadius)
                        .fill(Color.white.opacity(0.001)) // hit target
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SegmentButtonStyle())
    }

    private var sensitiveToggle: some View {
        HStack {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("Sensitive Mode")
                .font(.system(size: 12))

            Spacer()

            Toggle("", isOn: Binding(
                get: { viewModel.snapshot.sensitiveMode },
                set: { viewModel.setSensitiveMode($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .popoverGlassSurface(
            tint: viewModel.snapshot.sensitiveMode ? DarkUtilityGlass.sensitivePurple.opacity(0.30) : nil,
            fallbackFill: viewModel.snapshot.sensitiveMode
                ? DarkUtilityGlass.sensitivePurple.opacity(0.06)
                : DarkUtilityGlass.subtleBackground,
            fallbackStroke: viewModel.snapshot.sensitiveMode
                ? DarkUtilityGlass.sensitivePurple.opacity(0.18)
                : DarkUtilityGlass.cardBorder,
            interactive: true
        )
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovering || configuration.isPressed ? .primary : .secondary)
            .background(
                RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverSegmentRadius)
                    .fill(configuration.isPressed
                          ? Color.white.opacity(0.08)
                          : isHovering ? Color.white.opacity(0.05) : Color.clear)
            )
            .onHover { isHovering = $0 }
    }
}

import SwiftUI

struct HealthDetailCard: View {
    let snapshot: BridgeSnapshot

    var body: some View {
        VStack(spacing: 6) {
            healthRow("Daemon", value: snapshot.daemonLaunchdState)
            healthRow("Watcher", value: snapshot.watcherLaunchdState)
            if let waState = snapshot.whatsappLaunchdState {
                healthRow("WhatsApp", value: waState)
            }
            healthRow("Queue", value: "\(snapshot.queueDepth) pending",
                       isHealthy: snapshot.queueDepth <= 10,
                       warnColor: DarkUtilityGlass.warningAmber)
        }
        .padding(10)
        .padding(.horizontal, 2)
        .popoverGlassSurface(
            tint: DarkUtilityGlass.warningAmber.opacity(0.24),
            fallbackFill: DarkUtilityGlass.warningAmber.opacity(0.06),
            fallbackStroke: DarkUtilityGlass.warningAmber.opacity(0.12)
        )
    }

    private func healthRow(_ label: String, value: String, isHealthy: Bool? = nil, warnColor: Color = DarkUtilityGlass.errorRed) -> some View {
        let healthy = isHealthy ?? (value == "loaded")
        return HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(healthy ? DarkUtilityGlass.activeGreen : warnColor)
        }
    }
}

import SwiftUI

struct HealthStripView: View {
    let snapshot: BridgeSnapshot

    var body: some View {
        HStack(spacing: 16) {
            healthItem("Queue", value: "\(snapshot.queueDepth)", warn: snapshot.queueDepth > 10)
            healthItem("Daemon", value: snapshot.daemonLaunchdState, warn: snapshot.daemonLaunchdState != "loaded")
            healthItem("Watcher", value: snapshot.watcherLaunchdState, warn: snapshot.watcherLaunchdState != "loaded")
        }
        .font(.caption2)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func healthItem(_ label: String, value: String, warn: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(warn ? .orange : .primary)
        }
    }
}

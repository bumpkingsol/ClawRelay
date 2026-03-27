import SwiftUI

struct StatusHeaderView: View {
    let snapshot: BridgeSnapshot

    var body: some View {
        HStack {
            Image(systemName: snapshot.trackingState.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(stateColor)
            VStack(alignment: .leading) {
                Text(stateLabel)
                    .font(.headline)
                if let detail = stateDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var stateLabel: String {
        switch snapshot.trackingState {
        case .active: return "Active"
        case .paused: return "Paused"
        case .sensitive: return "Sensitive Mode"
        case .needsAttention: return "Needs Attention"
        }
    }

    private var stateColor: Color {
        switch snapshot.trackingState {
        case .active: return .green
        case .paused: return .orange
        case .sensitive: return .purple
        case .needsAttention: return .red
        }
    }

    private var stateDetail: String? {
        switch snapshot.trackingState {
        case .paused:
            if let until = snapshot.pauseUntil, until != "indefinite" {
                return "Until \(until)"
            }
            return "Indefinitely"
        case .sensitive:
            return "Reduced capture active"
        case .needsAttention:
            if snapshot.daemonLaunchdState == "missing" { return "Daemon not running" }
            if snapshot.watcherLaunchdState == "missing" { return "File watcher stopped" }
            return nil
        default:
            return nil
        }
    }
}

import SwiftUI

struct StatusHeaderView: View {
    let snapshot: BridgeSnapshot

    var body: some View {
        HStack(alignment: .center) {
            // Icon container
            RoundedRectangle(cornerRadius: DarkUtilityGlass.popoverCardRadius)
                .fill(stateColor.opacity(0.12))
                .frame(width: 34, height: 34)
                .overlay {
                    stateIcon
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(stateLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)

                Text(stateSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(stateColor)
            }

            Spacer()

            Text("Queue: \(snapshot.queueDepth)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(snapshot.queueDepth > 10 ? DarkUtilityGlass.warningAmber : DarkUtilityGlass.mutedGray)
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            DarkUtilityGlass.divider.frame(height: 1)
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch snapshot.trackingState {
        case .active:
            Circle()
                .fill(DarkUtilityGlass.activeGreen)
                .frame(width: 10, height: 10)
                .shadow(color: DarkUtilityGlass.activeGreen.opacity(0.27), radius: 4)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 14))
                .foregroundStyle(DarkUtilityGlass.warningAmber)
        case .sensitive:
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 14))
                .foregroundStyle(DarkUtilityGlass.sensitivePurple)
        case .needsAttention:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(DarkUtilityGlass.warningAmber)
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

    private var stateSubtitle: String {
        switch snapshot.trackingState {
        case .active:
            return snapshot.healthSummary
        case .paused:
            return pauseSubtitle
        case .sensitive:
            return "Reduced capture active"
        case .needsAttention:
            let down = snapshot.totalServiceCount - snapshot.healthyServiceCount
            return "\(down) service\(down == 1 ? "" : "s") down"
        }
    }

    private var pauseSubtitle: String {
        guard let until = snapshot.pauseUntil, until != "indefinite" else {
            return "Paused indefinitely"
        }
        if let epoch = TimeInterval(until) {
            let remaining = epoch - Date().timeIntervalSince1970
            if remaining <= 0 { return "Resuming..." }
            let minutes = Int(ceil(remaining / 60))
            if minutes >= 60 {
                let hours = minutes / 60
                return "Resumes in \(hours)h \(minutes % 60)m"
            }
            return "Resumes in \(minutes)m"
        }
        return "Until \(until)"
    }

    private var stateColor: Color {
        switch snapshot.trackingState {
        case .active: return DarkUtilityGlass.activeGreen
        case .paused: return DarkUtilityGlass.warningAmber
        case .sensitive: return DarkUtilityGlass.sensitivePurple
        case .needsAttention: return DarkUtilityGlass.warningAmber
        }
    }
}

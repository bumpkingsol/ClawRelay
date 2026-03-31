import SwiftUI

struct NotificationCardView: View {
    let notification: MeetingNotification
    let onPin: () -> Void
    let onDismiss: () -> Void

    @State private var remainingFraction: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: categoryIcon)
                    .foregroundStyle(priorityColor)
                Text(notification.card.title)
                    .font(.callout.bold())
                    .foregroundStyle(.primary)
                Spacer()
                if notification.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Text(notification.card.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)

            HStack {
                Spacer()
                if !notification.isPinned {
                    Text("\(Int(notification.remainingSeconds))s")
                        .font(DarkUtilityGlass.monoCaption)
                        .foregroundStyle(.tertiary)
                }
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.15))
                        .frame(width: geo.size.width)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(priorityColor.opacity(0.6))
                                .frame(width: geo.size.width * remainingFraction)
                        }
                }
                .frame(width: 60, height: 4)
            }
        }
        .padding(14)
        .glassCard()
        .onTapGesture { onPin() }
        .contextMenu {
            Button("Dismiss") { onDismiss() }
            if !notification.isPinned {
                Button("Pin") { onPin() }
            }
        }
        .onAppear { startCountdown() }
    }

    private var categoryIcon: String {
        switch notification.card.category {
        case "behavioural": return "brain.head.profile"
        case "data":        return "chart.bar.fill"
        case "context":     return "doc.text.fill"
        default:            return "lightbulb.fill"
        }
    }

    private var priorityColor: Color {
        switch notification.card.priority {
        case "high":   return .orange
        case "medium": return .blue
        case "low":    return .secondary
        default:       return .blue
        }
    }

    private func startCountdown() {
        guard !notification.isPinned else {
            remainingFraction = 1.0
            return
        }
        withAnimation(.linear(duration: notification.remainingSeconds)) {
            remainingFraction = 0.0
        }
    }
}

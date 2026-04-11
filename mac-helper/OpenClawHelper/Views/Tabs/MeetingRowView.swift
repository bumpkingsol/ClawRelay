import SwiftUI

struct MeetingRowView: View {
    let meeting: MeetingRecord
    let onViewTranscript: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                    Text("\(meeting.formattedDate) · \(meeting.app ?? "") · \(meeting.formattedDuration)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let progress = meeting.captureProgressDescription,
                       meeting.processingStatus == "awaiting_frames" || meeting.processingStatus == "ready" {
                        Text(progress)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Participant avatars
                HStack(spacing: -4) {
                    ForEach(meeting.participants.prefix(3), id: \.self) { name in
                        initialsCircle(for: name, size: 22)
                    }
                    if meeting.participants.count > 3 {
                        Text("+\(meeting.participants.count - 3)")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.orange.opacity(0.3)))
                    }
                }

                statusBadge
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            // Expanded detail
            if isExpanded, let summary = meeting.summaryMd, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().padding(.vertical, 8)
                    Text(summary)
                        .font(.system(size: 11))
                        .lineSpacing(3)

                    if meeting.hasTranscript {
                        Button("View transcript") {
                            onViewTranscript()
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
                .strokeBorder(Color.primary.opacity(isExpanded ? 0.08 : 0.06), lineWidth: 1)
        )
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch meeting.processingStatus {
            case "awaiting_frames":
                return ("Awaiting frames", .orange)
            case "ready":
                return ("Ready to process", .blue)
            case "processed":
                return (meeting.purgeStatus == "summary_only" ? "Raw purged" : "Summary ready",
                        meeting.purgeStatus == "summary_only" ? .gray : .green)
            case "failed":
                return ("Capture failed", .red)
            default:
                if meeting.hasTranscript || meeting.summaryMd != nil {
                    return ("Summary ready", .green)
                }
                return ("Processing", .blue)
            }
        }()

        return Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.1).cornerRadius(4))
    }

    private func initialsCircle(for name: String, size: CGFloat) -> some View {
        let parts = name.split(separator: " ")
        let initials = parts.count >= 2
            ? "\(parts[0].prefix(1))\(parts[1].prefix(1))"
            : String(name.prefix(2))

        return Text(initials.uppercased())
            .font(.system(size: size * 0.4, weight: .semibold))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.blue.opacity(0.3)))
            .clipShape(Circle())
    }
}

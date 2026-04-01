import SwiftUI

struct ParticipantRowView: View {
    let participant: ParticipantRecord
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row
            HStack(spacing: 10) {
                Text(participant.initials)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.purple.opacity(0.3)))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(participant.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text("\(participant.meetingsObserved) meetings")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(participant.oneLiner)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            // Expanded profile
            if isExpanded, let profile = participant.profile {
                let patterns = profile["patterns"]?.objectValue ?? profile
                VStack(alignment: .leading, spacing: 10) {
                    Divider().padding(.vertical, 8)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        profileQuadrant(
                            title: "Decision Style",
                            text: [patterns["decision_style"], patterns["authority_deference"]]
                                .compactMap { $0?.stringValue }.joined(separator: " ")
                        )
                        profileQuadrant(
                            title: "Stress Triggers",
                            text: [patterns["stress_triggers"], patterns["money_reaction"]]
                                .compactMap { $0?.stringValue }.joined(separator: " ")
                        )
                        profileQuadrant(
                            title: "Engagement",
                            text: [patterns["engagement_peak"], patterns["commitment_signals"]]
                                .compactMap { $0?.stringValue }.joined(separator: " ")
                        )
                        profileQuadrant(
                            title: "Reliability",
                            text: patterns["reliability"]?.stringValue ?? ""
                        )
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

    private func profileQuadrant(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "—" : text)
                .font(.system(size: 11))
                .lineSpacing(2)
        }
    }
}

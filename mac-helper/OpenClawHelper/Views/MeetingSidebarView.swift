import SwiftUI
import AppKit

final class MeetingSidebarPanel: NSPanel {
    init() {
        let width: CGFloat = 320
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let height = screen.visibleFrame.height

        super.init(
            contentRect: NSRect(
                x: screen.visibleFrame.maxX - width,
                y: screen.visibleFrame.minY,
                width: width,
                height: height
            ),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        sharingType = .none
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func showWithContent<Content: View>(_ content: Content) {
        let hostingView = NSHostingView(rootView:
            content
                .environment(\.colorScheme, .dark)
        )
        contentView = hostingView
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}

struct MeetingSidebarView: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let points = viewModel.briefing?.talkingPoints, !points.isEmpty {
                        talkingPointsSection(points)
                    }

                    if let profiles = viewModel.briefing?.participantProfiles, !profiles.isEmpty {
                        participantProfilesSection(profiles)
                    }

                    if let cards = viewModel.briefing?.cards, !cards.isEmpty {
                        briefingCardsSection(cards)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DarkUtilityGlass.background)
    }

    private var sidebarHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.briefing?.topic ?? "Meeting")
                    .font(.headline)
                if let attendees = viewModel.briefing?.attendees {
                    Text(attendees.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: { viewModel.toggleSidebar() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private func talkingPointsSection(_ points: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Talking Points", systemImage: "checklist")
                .font(.subheadline.bold())

            ForEach(points, id: \.self) { point in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    Text(point)
                        .font(.caption)
                }
            }
        }
    }

    private func participantProfilesSection(_ profiles: [String: ParticipantProfile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Participants", systemImage: "person.2.fill")
                .font(.subheadline.bold())

            ForEach(Array(profiles.keys.sorted()), id: \.self) { name in
                if let profile = profiles[name] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption.bold())
                        if let style = profile.decisionStyle {
                            Text("Style: \(style.replacingOccurrences(of: "_", with: " "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let advice = profile.framingAdvice {
                            Text(advice)
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        if let triggers = profile.stressTriggers, !triggers.isEmpty {
                            Text("Stress: \(triggers.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(8)
                    .glassCard()
                }
            }
        }
    }

    private func briefingCardsSection(_ cards: [BriefingCard]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Briefing Cards", systemImage: "rectangle.stack.fill")
                .font(.subheadline.bold())

            ForEach(cards) { card in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(card.title)
                            .font(.caption.bold())
                        Spacer()
                        if viewModel.sessionManager.briefingCache.firedCards.contains(card.title) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        Text(card.priority)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                card.priority == "high" ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2),
                                in: Capsule()
                            )
                            .foregroundStyle(card.priority == "high" ? .orange : .blue)
                    }
                    Text(card.body)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Keywords: \(card.triggerKeywords.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .glassCard()
            }
        }
    }
}

import SwiftUI
import AppKit

// MARK: - Sidebar Card Type

enum SidebarCardType: String {
    case talkingPoint, context, suggestion, warning

    var color: Color {
        switch self {
        case .talkingPoint: return Color(red: 0.545, green: 0.361, blue: 0.965)
        case .context: return Color(red: 0.345, green: 0.651, blue: 1.0)
        case .suggestion: return Color(red: 0.247, green: 0.725, blue: 0.314)
        case .warning: return Color(red: 0.824, green: 0.600, blue: 0.133)
        }
    }

    var label: String {
        switch self {
        case .talkingPoint: return "TALKING POINT"
        case .context: return "CONTEXT"
        case .suggestion: return "SUGGESTION"
        case .warning: return "WARNING"
        }
    }

    static func from(category: String) -> SidebarCardType {
        switch category {
        case "context": return .context
        case "behavioural": return .warning
        case "data": return .talkingPoint
        default: return .suggestion
        }
    }
}

// MARK: - Meeting Sidebar Panel (CGWindowList tracking)

final class MeetingSidebarPanel: NSPanel {
    private var trackingTimer: Timer?
    private var meetingAppBundleId: String?
    private let sidebarWidth: CGFloat = 300

    init(meetingAppBundleId: String?) {
        self.meetingAppBundleId = meetingAppBundleId

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(
            x: screen.visibleFrame.maxX - sidebarWidth,
            y: screen.visibleFrame.origin.y,
            width: sidebarWidth,
            height: screen.visibleFrame.height
        )

        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = NSColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 0.95)
        isOpaque = false
        hasShadow = true
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
        stopTracking()
        orderOut(nil)
    }

    func startTracking() {
        updatePosition()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updatePosition()
        }
    }

    func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func updatePosition() {
        guard let bundleId = meetingAppBundleId,
              let meetingFrame = findMeetingWindowFrame(bundleId: bundleId) else {
            positionAtScreenEdge()
            return
        }

        let newFrame = NSRect(
            x: meetingFrame.maxX,
            y: meetingFrame.origin.y,
            width: sidebarWidth,
            height: meetingFrame.height
        )
        setFrame(newFrame, display: true, animate: false)
    }

    private func findMeetingWindowFrame(bundleId: String) -> CGRect? {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }

            let app = NSRunningApplication(processIdentifier: ownerPID)
            if app?.bundleIdentifier == bundleId {
                return CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0,
                    height: bounds["Height"] ?? 0
                )
            }
        }
        return nil
    }

    private func positionAtScreenEdge() {
        guard let screen = NSScreen.main else { return }
        let newFrame = NSRect(
            x: screen.visibleFrame.maxX - sidebarWidth,
            y: screen.visibleFrame.origin.y,
            width: sidebarWidth,
            height: screen.visibleFrame.height
        )
        setFrame(newFrame, display: true, animate: false)
    }

    deinit {
        stopTracking()
    }
}

// MARK: - Meeting Sidebar View

struct MeetingSidebarView: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Section 1: Header with recording dot and timer
            sidebarHeader

            Divider()
                .background(DarkUtilityGlass.divider)

            // Section 2: Participants
            if let attendees = viewModel.briefing?.attendees, !attendees.isEmpty {
                participantsBar(attendees)
                Divider()
                    .background(DarkUtilityGlass.divider)
            }

            // Section 3: Intelligence cards (scrollable)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let points = viewModel.briefing?.talkingPoints, !points.isEmpty {
                        ForEach(points, id: \.self) { point in
                            intelligenceCard(
                                type: .talkingPoint,
                                title: point,
                                body: nil
                            )
                        }
                    }

                    if let cards = viewModel.briefing?.cards, !cards.isEmpty {
                        ForEach(cards) { card in
                            let cardType = SidebarCardType.from(category: card.category)
                            intelligenceCard(
                                type: cardType,
                                title: card.title,
                                body: card.body,
                                isFired: viewModel.sessionManager.briefingCache.firedCards.contains(card.title)
                            )
                        }
                    }

                    if let profiles = viewModel.briefing?.participantProfiles, !profiles.isEmpty {
                        ForEach(Array(profiles.keys.sorted()), id: \.self) { name in
                            if let profile = profiles[name] {
                                profileCard(name: name, profile: profile)
                            }
                        }
                    }
                }
                .padding(12)
            }

            Divider()
                .background(DarkUtilityGlass.divider)

            // Section 4: Transcript ticker (fixed bottom)
            transcriptTicker
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.07, blue: 0.09))
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            // Recording dot
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: .red.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.briefing?.topic ?? "Meeting")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(viewModel.formattedElapsed)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: { viewModel.toggleSidebar() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Participants Bar

    private func participantsBar(_ attendees: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attendees, id: \.self) { attendee in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(DarkUtilityGlass.accentBlue.opacity(0.3))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Text(String(attendee.prefix(1)).uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(DarkUtilityGlass.accentBlue)
                            )
                        Text(attendee)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Intelligence Card

    private func intelligenceCard(
        type: SidebarCardType,
        title: String,
        body: String?,
        isFired: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(type.color)
                    .frame(width: 3, height: 12)

                Text(type.label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(type.color)
                    .tracking(0.5)

                Spacer()

                if isFired {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkUtilityGlass.activeGreen)
                }
            }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)

            if let body = body, !body.isEmpty {
                Text(body)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .background(DarkUtilityGlass.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(type.color.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Profile Card

    private func profileCard(name: String, profile: ParticipantProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(SidebarCardType.context.color)
                    .frame(width: 3, height: 12)

                Text("PARTICIPANT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SidebarCardType.context.color)
                    .tracking(0.5)
            }

            Text(name.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)

            if let style = profile.decisionStyle {
                Text("Style: \(style.replacingOccurrences(of: "_", with: " "))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if let advice = profile.framingAdvice {
                Text(advice)
                    .font(.system(size: 10))
                    .foregroundStyle(DarkUtilityGlass.accentBlue)
                    .lineLimit(2)
            }

            if let triggers = profile.stressTriggers, !triggers.isEmpty {
                Text("Avoid: \(triggers.joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundStyle(DarkUtilityGlass.warningAmber)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(DarkUtilityGlass.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SidebarCardType.context.color.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Transcript Ticker

    private var transcriptTicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(DarkUtilityGlass.activeGreen)

            if let lastNotification = viewModel.notifications.last {
                Text(lastNotification.triggerKeyword)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Listening...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text("\(viewModel.firedCardCount) cards fired")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.3))
    }
}

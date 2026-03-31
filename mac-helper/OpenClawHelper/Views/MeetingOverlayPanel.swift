import SwiftUI
import AppKit

final class MeetingOverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        sharingType = .none
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        positionTopRight()
    }

    func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelWidth: CGFloat = 360
        let margin: CGFloat = 16

        let origin = NSPoint(
            x: screenFrame.maxX - panelWidth - margin,
            y: screenFrame.maxY - frame.height
        )
        setFrameOrigin(origin)
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

struct OverlayNotificationsView: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(viewModel.notifications) { notification in
                NotificationCardView(
                    notification: notification,
                    onPin: { viewModel.pinNotification(notification.id) },
                    onDismiss: { viewModel.dismissNotification(notification.id) }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
            }
            Spacer()
        }
        .padding(.top, 16)
        .frame(width: 340)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.notifications.count)
    }
}

import SwiftUI
import Combine

@MainActor
final class MeetingViewModel: ObservableObject {
    @Published var showSidebar: Bool = false
    @Published var showOverlay: Bool = true

    let sessionManager: MeetingSessionManager

    private var overlayPanel: MeetingOverlayPanel?
    private var sidebarPanel: MeetingSidebarPanel?
    private var cancellables = Set<AnyCancellable>()

    init(sessionManager: MeetingSessionManager = MeetingSessionManager()) {
        self.sessionManager = sessionManager

        sessionManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        sessionManager.briefingCache.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        sessionManager.$state
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updatePanels()
            }
            .store(in: &cancellables)

        $showSidebar
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updatePanels()
            }
            .store(in: &cancellables)
    }

    func updatePanels() {
        switch state {
        case .recording:
            if showOverlay && overlayPanel == nil {
                let panel = MeetingOverlayPanel()
                panel.showWithContent(OverlayNotificationsView(viewModel: self))
                overlayPanel = panel
            }
            if showSidebar && sidebarPanel == nil {
                let panel = MeetingSidebarPanel()
                panel.showWithContent(MeetingSidebarView(viewModel: self))
                sidebarPanel = panel
            } else if !showSidebar {
                sidebarPanel?.dismiss()
                sidebarPanel = nil
            }

        default:
            overlayPanel?.dismiss()
            overlayPanel = nil
            sidebarPanel?.dismiss()
            sidebarPanel = nil
        }
    }

    var state: MeetingLifecycleState { sessionManager.state }
    var isActive: Bool { state.isActive }
    var meetingId: String? { sessionManager.sessionInfo?.meetingId }
    var formattedElapsed: String { sessionManager.formattedElapsed }
    var briefing: BriefingPackage? { sessionManager.briefingCache.currentBriefing }
    var notifications: [MeetingNotification] { sessionManager.briefingCache.activeNotifications }
    var firedCardCount: Int { sessionManager.briefingCache.firedCards.count }

    func startMeeting() {
        let app = sessionManager.detector.detectedApp
        sessionManager.startMeeting(app: app)
    }

    func stopMeeting() {
        sessionManager.stopMeeting()
    }

    func cancelFinalization() {
        sessionManager.cancelFinalization()
    }

    func toggleSidebar() {
        showSidebar.toggle()
    }

    func pinNotification(_ id: UUID) {
        sessionManager.briefingCache.pinNotification(id)
    }

    func dismissNotification(_ id: UUID) {
        sessionManager.briefingCache.dismissNotification(id)
    }

    func shutdown() {
        sessionManager.shutdown()
    }
}

extension MeetingViewModel {
    static var preview: MeetingViewModel {
        MeetingViewModel()
    }
}

import SwiftUI
import Combine

@MainActor
final class MeetingViewModel: ObservableObject {
    @Published var showSidebar: Bool = false
    @Published var showOverlay: Bool = true
    @Published var meetingHistory: [MeetingRecord] = []
    @Published var participantProfiles: [ParticipantRecord] = []
    @Published var selectedMeetingTranscript: TranscriptResponse?
    @Published var transcriptFetchState: MeetingTranscriptFetchState = .idle
    @Published var lastMeetingError: String?
    @Published var meetingsSubTab: MeetingsSubTab = .meetings

    enum MeetingsSubTab {
        case meetings, people
    }

    let sessionManager: MeetingSessionManager
    private let runner: BridgeCommandRunner

    private var overlayPanel: MeetingOverlayPanel?
    private var sidebarPanel: MeetingSidebarPanel?
    private var cancellables = Set<AnyCancellable>()

    init(runner: BridgeCommandRunner = BridgeCommandRunner(), sessionManager: MeetingSessionManager? = nil) {
        let sessionManager = sessionManager ?? MeetingSessionManager()

        self.runner = runner
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
            if showSidebar {
                showSidebarPanel()
            } else {
                dismissSidebarPanel()
            }

        default:
            overlayPanel?.dismiss()
            overlayPanel = nil
            dismissSidebarPanel()
        }
    }

    private func showSidebarPanel() {
        guard sidebarPanel == nil else { return }
        let bundleId = sessionManager.detectedMeetingAppBundleId
        let panel = MeetingSidebarPanel(meetingAppBundleId: bundleId)
        panel.showWithContent(MeetingSidebarView(viewModel: self))
        panel.startTracking()
        sidebarPanel = panel
    }

    private func dismissSidebarPanel() {
        sidebarPanel?.dismiss()
        sidebarPanel = nil
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
        sessionManager.startMeeting(app: app, manual: true)
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

    func fetchMeetingHistory(days: Int = 7) {
        let capturedRunner = runner
        Task.detached {
            do {
                let raw = try capturedRunner.runActionWithOutput("meetings", "\(days)")
                let decoded = try JSONDecoder().decode(MeetingsResponse.self, from: raw)
                await MainActor.run { [weak self] in
                    self?.meetingHistory = decoded.meetings
                    self?.lastMeetingError = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastMeetingError = error.localizedDescription
                }
            }
        }
    }

    func fetchParticipants() {
        let capturedRunner = runner
        Task.detached {
            do {
                let raw = try capturedRunner.runActionWithOutput("participants")
                let decoded = try JSONDecoder().decode(ParticipantsResponse.self, from: raw)
                await MainActor.run { [weak self] in
                    self?.participantProfiles = decoded.participants
                    self?.lastMeetingError = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastMeetingError = error.localizedDescription
                }
            }
        }
    }

    func fetchTranscript(for meetingId: String) {
        transcriptFetchState = .loading
        let capturedRunner = runner
        Task.detached {
            do {
                let raw = try capturedRunner.runActionWithOutput("transcript", meetingId)
                let decoded = try JSONDecoder().decode(TranscriptResponse.self, from: raw)
                await MainActor.run { [weak self] in
                    self?.selectedMeetingTranscript = decoded
                    if decoded.error == "purged" {
                        self?.transcriptFetchState = .summaryOnly
                    } else if let transcript = decoded.transcript, !transcript.isEmpty {
                        self?.transcriptFetchState = .live
                    } else {
                        self?.transcriptFetchState = .missing
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.selectedMeetingTranscript = nil
                    self?.transcriptFetchState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func dismissTranscript() {
        selectedMeetingTranscript = nil
        transcriptFetchState = .idle
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

enum MeetingTranscriptFetchState: Equatable {
    case idle
    case loading
    case live
    case summaryOnly
    case missing
    case failed(String)
}

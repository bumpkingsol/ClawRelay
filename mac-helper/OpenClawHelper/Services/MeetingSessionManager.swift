import Foundation
import Combine
import AppKit

@MainActor
final class MeetingSessionManager: ObservableObject {
    @Published private(set) var state: MeetingLifecycleState = .idle
    @Published private(set) var sessionInfo: MeetingSessionInfo?
    @Published private(set) var elapsedSeconds: Int = 0

    let detector: MeetingDetectorService
    let workerManager: MeetingWorkerManager
    let briefingCache: BriefingCacheService

    private var cancellables = Set<AnyCancellable>()
    private var elapsedTimer: Timer?
    private var manuallyStarted: Bool = false
    private var consentTask: Task<Void, Never>?
    private var pendingMeetingId: String?
    private var pendingMeetingApp: String?

    init(
        detector: MeetingDetectorService? = nil,
        workerManager: MeetingWorkerManager? = nil,
        briefingCache: BriefingCacheService? = nil
    ) {
        self.detector = detector ?? MeetingDetectorService()
        self.workerManager = workerManager ?? MeetingWorkerManager()
        self.briefingCache = briefingCache ?? BriefingCacheService()

        setupAutoDetection()
    }

    func startMeeting(meetingId: String? = nil, app: String? = nil, manual: Bool = false) {
        guard state == .idle else { return }
        let id = meetingId ?? generateMeetingId(app: app)
        pendingMeetingId = id
        pendingMeetingApp = app
        state = .awaitingConsent

        if manual {
            manuallyStarted = true
            beginPreparing(meetingId: id, app: app)
        } else {
            requestConsent()
        }
    }

    func stopMeeting() {
        guard state == .recording || state == .preparing else { return }
        beginFinalizing()
    }

    func cancelFinalization() {
        guard state == .finalizing else { return }
        transitionToIdle()
    }

    func shutdown() {
        detector.stopMonitoring()
        if state != .idle {
            workerManager.stopWorker()
        }
        briefingCache.reset()
    }

    private func beginPreparing(meetingId: String, app: String?) {
        guard state == .awaitingConsent else { return }
        state = .preparing
        sessionInfo = MeetingSessionInfo(
            meetingId: meetingId,
            startedAt: Date(),
            app: app,
            transcriptSegments: 0,
            screenshotsTaken: 0,
            briefingLoaded: false,
            cardsSurfaced: 0,
            workerPid: nil
        )

        briefingCache.loadBriefing(meetingId: meetingId)
        if briefingCache.currentBriefing != nil {
            sessionInfo?.briefingLoaded = true
        }

        do {
            try workerManager.startWorker(meetingId: meetingId)
            sessionInfo?.workerPid = workerManager.workerPid
            transitionToRecording()
        } catch {
            transitionToIdle()
        }
    }

    private func transitionToRecording() {
        state = .recording
        elapsedSeconds = 0

        briefingCache.startBufferWatch()

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func beginFinalizing() {
        state = .finalizing
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        briefingCache.stopBufferWatch()

        workerManager.stopWorker()

        Task {
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                if !workerManager.isRunning { break }
            }
            transitionToIdle()
        }
    }

    private func transitionToIdle() {
        state = .idle
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        consentTask?.cancel()
        consentTask = nil
        pendingMeetingId = nil
        pendingMeetingApp = nil
        sessionInfo = nil
        elapsedSeconds = 0
        manuallyStarted = false
        briefingCache.reset()
    }

    private func requestConsent() {
        consentTask?.cancel()
        consentTask = Task { [weak self] in
            guard let self else { return }

            let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Meeting Detected"
                    alert.informativeText = "A meeting was detected. Do you want to record it?"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Accept")
                    alert.addButton(withTitle: "Decline")

                    // 15-second auto-decline timer
                    let timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { _ in
                        alert.window.orderOut(nil)
                        NSApp.stopModal(withCode: .alertSecondButtonReturn)
                    }

                    let response = NSApp.runModal(for: alert.window)
                    timer.invalidate()

                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }

            guard !Task.isCancelled else { return }

            if accepted {
                guard let id = self.pendingMeetingId else { return }
                self.manuallyStarted = false
                self.beginPreparing(meetingId: id, app: self.pendingMeetingApp)
            } else {
                self.transitionToIdle()
                self.suppressDetectionUntilAppCloses()
            }
        }
    }

    private func suppressDetectionUntilAppCloses() {
        NotificationCenter.default.post(name: .meetingConsentDeclined, object: nil)
    }

    private func setupAutoDetection() {
        detector.startMonitoring()

        detector.$isMeetingDetected
            .removeDuplicates()
            .sink { [weak self] detected in
                guard let self else { return }
                if detected && self.state == .idle {
                    let app = self.detector.detectedApp
                    self.startMeeting(app: app, manual: false)
                } else if !detected && self.state == .recording && !self.manuallyStarted {
                    self.beginFinalizing()
                }
            }
            .store(in: &cancellables)
    }

    private func generateMeetingId(app: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let appSuffix = app ?? "unknown"
        return "\(timestamp)-\(appSuffix)"
    }

    var formattedElapsed: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension Notification.Name {
    static let meetingConsentDeclined = Notification.Name("meetingConsentDeclined")
}

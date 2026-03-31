import Combine
import CoreAudio
import AppKit

/// Detects active meetings by monitoring microphone usage and meeting app presence.
@MainActor
final class MeetingDetectorService: ObservableObject {
    @Published private(set) var isMeetingDetected: Bool = false
    @Published private(set) var detectedApp: String? = nil

    private var micListenerBlock: AudioObjectPropertyListenerBlock?
    private var debounceTask: Task<Void, Never>?
    private var pollTimer: Timer?

    private let debounceSeconds: TimeInterval = 5.0
    private let silenceTimeoutSeconds: TimeInterval = 60.0
    private var micActiveSince: Date?
    private var micSilentSince: Date?
    private var suppressedUntilAppCloses: Bool = false
    private var consentDeclinedObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?

    func startMonitoring() {
        listenToMicrophoneState()
        startAppPolling()
        observeConsentDeclined()
        observeAppTermination()
    }

    func stopMonitoring() {
        removeAudioListener()
        pollTimer?.invalidate()
        pollTimer = nil
        debounceTask?.cancel()
        debounceTask = nil
        if let observer = consentDeclinedObserver {
            NotificationCenter.default.removeObserver(observer)
            consentDeclinedObserver = nil
        }
        if let observer = appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appTerminationObserver = nil
        }
    }

    private func listenToMicrophoneState() {
        var defaultDevice = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &defaultDevice
        )
        guard defaultDevice != kAudioObjectUnknown else { return }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleMicStateChange(deviceId: defaultDevice)
            }
        }
        micListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            defaultDevice,
            &runningAddress,
            DispatchQueue.main,
            block
        )
    }

    private func handleMicStateChange(deviceId: AudioObjectID) {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceId, &address, 0, nil, &size, &isRunning)

        if isRunning != 0 {
            micActiveSince = Date()
            micSilentSince = nil
            debounceMeetingCheck()
        } else {
            micActiveSince = nil
            micSilentSince = Date()
            debounceMeetingEnd()
        }
    }

    private func removeAudioListener() {
        micListenerBlock = nil
    }

    private func startAppPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scanForMeetingApps()
            }
        }
    }

    private func scanForMeetingApps() {
        let apps = NSWorkspace.shared.runningApplications

        if apps.contains(where: { $0.bundleIdentifier == "us.zoom.xos" }) {
            if isZoomInMeeting() {
                detectedApp = "zoom"
                return
            }
        }

        if apps.contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
            if isChromeOnGoogleMeet() {
                detectedApp = "google-meet"
                return
            }
        }

        detectedApp = nil
    }

    private func isZoomInMeeting() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return windowList.contains { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner == "zoom.us",
                  let title = info[kCGWindowName as String] as? String else { return false }
            return title.contains("Zoom Meeting")
        }
    }

    private func isChromeOnGoogleMeet() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return windowList.contains { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner == "Google Chrome",
                  let title = info[kCGWindowName as String] as? String else { return false }
            return title.lowercased().contains("meet.google.com")
        }
    }

    private func debounceMeetingCheck() {
        guard !suppressedUntilAppCloses else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard !self.suppressedUntilAppCloses else { return }
            if self.micActiveSince != nil && self.detectedApp != nil {
                self.isMeetingDetected = true
            }
        }
    }

    private func observeConsentDeclined() {
        consentDeclinedObserver = NotificationCenter.default.addObserver(
            forName: .meetingConsentDeclined,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suppressedUntilAppCloses = true
            }
        }
    }

    private func observeAppTermination() {
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.suppressedUntilAppCloses else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let meetingBundleIds = ["us.zoom.xos", "com.google.Chrome"]
                if let bundleId = app.bundleIdentifier, meetingBundleIds.contains(bundleId) {
                    self.suppressedUntilAppCloses = false
                }
            }
        }
    }

    private func debounceMeetingEnd() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.micSilentSince != nil && self.detectedApp == nil {
                self.isMeetingDetected = false
            }
        }
    }
}

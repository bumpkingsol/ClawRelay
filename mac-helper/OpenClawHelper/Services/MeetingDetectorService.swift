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
    private var detectedMeetingSignature: String?
    private var suppressedMeetingSignature: String?

    func startMonitoring() {
        listenToMicrophoneState()
        startAppPolling()
        scanForMeetingApps()
    }

    func stopMonitoring() {
        removeAudioListener()
        pollTimer?.invalidate()
        pollTimer = nil
        debounceTask?.cancel()
        debounceTask = nil
        detectedMeetingSignature = nil
        suppressedMeetingSignature = nil
    }

    func suppressCurrentMeetingDetection() {
        suppressedMeetingSignature = detectedMeetingSignature
        isMeetingDetected = false
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
            if let signature = zoomMeetingSignature() {
                detectedApp = "zoom"
                detectedMeetingSignature = signature
                if suppressedMeetingSignature != signature {
                    suppressedMeetingSignature = nil
                }
                return
            }
        }

        if apps.contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
            if let signature = chromeGoogleMeetSignature() {
                detectedApp = "google-meet"
                detectedMeetingSignature = signature
                if suppressedMeetingSignature != signature {
                    suppressedMeetingSignature = nil
                }
                return
            }
        }

        detectedApp = nil
        detectedMeetingSignature = nil
        suppressedMeetingSignature = nil
    }

    private func zoomMeetingSignature() -> String? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        // Zoom window titles vary by version and locale ("Zoom Meeting", "Zoom Workplace",
        // meeting topic, etc). Just check for any zoom.us window at normal layer — if Zoom
        // is running and the mic is active, the user is in a meeting.
        for info in windowList {
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner == "zoom.us",
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }
            let title = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let title, !title.isEmpty {
                return "zoom:\(title)"
            }
            return "zoom:active"
        }
        return nil
    }

    private func chromeGoogleMeetSignature() -> String? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in windowList {
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner == "Google Chrome",
                  let title = info[kCGWindowName as String] as? String else { continue }
            let normalized = title.lowercased()
            if normalized.contains("meet.google.com") {
                return "google-meet:\(normalized)"
            }
        }
        return nil
    }

    private func debounceMeetingCheck() {
        guard suppressedMeetingSignature == nil || suppressedMeetingSignature != detectedMeetingSignature else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.debounceSeconds ?? 5))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.suppressedMeetingSignature == nil || self.suppressedMeetingSignature != self.detectedMeetingSignature else { return }
            if self.micActiveSince != nil && self.detectedApp != nil && self.detectedMeetingSignature != nil {
                self.isMeetingDetected = true
            }
        }
    }

    private func debounceMeetingEnd() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.silenceTimeoutSeconds ?? 60))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.micSilentSince != nil && self.detectedMeetingSignature == nil {
                self.isMeetingDetected = false
            }
        }
    }
}

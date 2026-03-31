# ClawRelay Meeting UI Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate meeting intelligence into ClawRelay's SwiftUI menu bar app. Add meeting detection, worker process management, live briefing card overlay, sidebar panel, and meeting controls in the existing popover. This is the UI and orchestration layer that connects ClawRelay to the `claw-meeting` binary built in Plan 1.

**Architecture:** ClawRelay detects meetings via CoreAudio device listeners and NSWorkspace app scanning. When a meeting starts (auto-detected or manual), it spawns the `claw-meeting` worker binary, loads pre-cached briefing packages from JC, watches the transcript buffer for keyword matches, and surfaces notification cards on an invisible overlay panel. The menu bar popover gains a meeting section with state display and controls.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit (NSPanel), CoreAudio (device property listeners), NSWorkspace, Foundation (Process, FileHandle)

**Spec:** `docs/superpowers/specs/2026-03-31-meeting-intelligence-design.md`

**Scope:** This is Plan 2 of 3. Plan 1 (claw-meeting binary) is a prerequisite. Plan 3 (server-side processing) follows.

**Dependencies:** Plan 1's `claw-meeting` binary must be buildable, but the UI integration can be developed in parallel using mock data and stub processes.

---

## File Structure

### New Files
```
mac-helper/OpenClawHelper/
  Models/
    MeetingState.swift              # Meeting lifecycle state enum (idle/preparing/recording/finalizing)
    BriefingPackage.swift           # Codable model for JC's pre-loaded briefing JSON
    MeetingNotification.swift       # Card data model for overlay notifications
  Services/
    MeetingDetectorService.swift    # CoreAudio device listener + NSWorkspace app scanning
    MeetingSessionManager.swift     # Lifecycle state machine, orchestrates all meeting services
    MeetingWorkerManager.swift      # Spawns/manages claw-meeting binary via Process
    BriefingCacheService.swift      # Loads briefing packages, matches transcript keywords
  ViewModels/
    MeetingViewModel.swift          # Binds meeting state to all UI components
  Views/
    MeetingStatusView.swift         # Meeting section in menu bar popover
    MeetingOverlayPanel.swift       # NSPanel wrapper (sharingType = .none)
    NotificationCardView.swift      # Slide-in notification card with countdown
    MeetingSidebarView.swift        # Full-height docked sidebar panel
```

### Modified Files
```
mac-helper/OpenClawHelper/
  AppModel.swift                    # Wire MeetingViewModel, forward objectWillChange
  Models/BridgeSnapshot.swift       # Add meeting state fields
  Views/MenuBarPopoverView.swift    # Add MeetingStatusView section
  OpenClawHelperApp.swift           # Register overlay window scene
mac-daemon/
  context-helperctl.sh              # Add meeting-start, meeting-stop, meeting-status actions
```

---

## Task 1: Meeting State Model + Briefing Package Model

**Files:**
- Create: `mac-helper/OpenClawHelper/Models/MeetingState.swift`
- Create: `mac-helper/OpenClawHelper/Models/BriefingPackage.swift`
- Create: `mac-helper/OpenClawHelper/Models/MeetingNotification.swift`

Data models first. Everything else depends on these types.

- [ ] **Step 1: Create MeetingState.swift**

This enum mirrors the lifecycle from the spec: idle -> preparing -> recording -> finalizing -> idle.

```swift
// mac-helper/OpenClawHelper/Models/MeetingState.swift
import Foundation

enum MeetingLifecycleState: String, Codable, Equatable {
    case idle
    case preparing
    case recording
    case finalizing

    var displayLabel: String {
        switch self {
        case .idle:       return "Idle"
        case .preparing:  return "Preparing..."
        case .recording:  return "Recording"
        case .finalizing: return "Finalizing..."
        }
    }

    var isActive: Bool {
        self == .recording || self == .preparing || self == .finalizing
    }

    var systemImage: String {
        switch self {
        case .idle:       return "mic.slash"
        case .preparing:  return "mic.badge.xmark"
        case .recording:  return "mic.fill"
        case .finalizing: return "waveform"
        }
    }

    var tintColor: String {
        switch self {
        case .idle:       return "secondary"
        case .preparing:  return "orange"
        case .recording:  return "red"
        case .finalizing: return "blue"
        }
    }
}

struct MeetingSessionInfo: Codable, Equatable {
    let meetingId: String
    let startedAt: Date
    var app: String?  // "zoom" or "google-meet"
    var transcriptSegments: Int
    var screenshotsTaken: Int
    var briefingLoaded: Bool
    var cardsSurfaced: Int
    var workerPid: Int32?
}
```

- [ ] **Step 2: Create BriefingPackage.swift**

Matches the JSON structure from the spec exactly.

```swift
// mac-helper/OpenClawHelper/Models/BriefingPackage.swift
import Foundation

struct BriefingPackage: Codable, Equatable {
    let meetingId: String
    let attendees: [String]
    let topic: String
    let cards: [BriefingCard]
    let participantProfiles: [String: ParticipantProfile]?
    let talkingPoints: [String]?

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case attendees, topic, cards
        case participantProfiles = "participant_profiles"
        case talkingPoints = "talking_points"
    }
}

struct BriefingCard: Codable, Equatable, Identifiable {
    let triggerKeywords: [String]
    let title: String
    let body: String
    let priority: String
    let category: String

    var id: String { title }

    enum CodingKeys: String, CodingKey {
        case triggerKeywords = "trigger_keywords"
        case title, body, priority, category
    }

    /// Case-insensitive partial match against transcript text.
    func matches(transcriptText: String) -> Bool {
        let lowered = transcriptText.lowercased()
        return triggerKeywords.contains { keyword in
            lowered.contains(keyword.lowercased())
        }
    }
}

struct ParticipantProfile: Codable, Equatable {
    let decisionStyle: String?
    let stressTriggers: [String]?
    let framingAdvice: String?

    enum CodingKeys: String, CodingKey {
        case decisionStyle = "decision_style"
        case stressTriggers = "stress_triggers"
        case framingAdvice = "framing_advice"
    }
}
```

- [ ] **Step 3: Create MeetingNotification.swift**

```swift
// mac-helper/OpenClawHelper/Models/MeetingNotification.swift
import Foundation

struct MeetingNotification: Identifiable, Equatable {
    let id: UUID
    let card: BriefingCard
    let triggeredAt: Date
    let triggerKeyword: String
    var isPinned: Bool
    var dismissAt: Date  // 8 seconds after triggeredAt unless pinned

    init(card: BriefingCard, triggerKeyword: String) {
        self.id = UUID()
        self.card = card
        self.triggeredAt = Date()
        self.triggerKeyword = triggerKeyword
        self.isPinned = false
        self.dismissAt = Date().addingTimeInterval(8.0)
    }

    var isExpired: Bool {
        !isPinned && Date() >= dismissAt
    }

    var remainingSeconds: TimeInterval {
        isPinned ? .infinity : max(0, dismissAt.timeIntervalSince(Date()))
    }
}
```

- [ ] **Step 4: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add mac-helper/OpenClawHelper/Models/MeetingState.swift \
        mac-helper/OpenClawHelper/Models/BriefingPackage.swift \
        mac-helper/OpenClawHelper/Models/MeetingNotification.swift
git commit -m "feat(meeting-ui): add MeetingState, BriefingPackage, and MeetingNotification models"
```

---

## Task 2: BridgeSnapshot Meeting Extension

**Files:**
- Modify: `mac-helper/OpenClawHelper/Models/BridgeSnapshot.swift`

Extend the existing status snapshot with meeting fields so helperctl can report meeting state.

- [ ] **Step 1: Add meeting fields to BridgeSnapshot**

Add optional meeting fields. These are optional because the meeting feature may not be active, and older helperctl versions won't emit them.

```swift
// Add to BridgeSnapshot struct, after existing fields:

    var meetingState: String?       // "idle", "preparing", "recording", "finalizing"
    var meetingId: String?
    var meetingElapsedSeconds: Int?
    var meetingWorkerPid: Int?
```

Update both `placeholder` and `needsAttentionPlaceholder` to include the new fields:

```swift
    static let placeholder = BridgeSnapshot(
        trackingState: .active,
        pauseUntil: nil,
        sensitiveMode: false,
        queueDepth: 0,
        daemonLaunchdState: "unknown",
        watcherLaunchdState: "unknown",
        meetingState: nil,
        meetingId: nil,
        meetingElapsedSeconds: nil,
        meetingWorkerPid: nil
    )

    static let needsAttentionPlaceholder = BridgeSnapshot(
        trackingState: .needsAttention,
        pauseUntil: nil,
        sensitiveMode: false,
        queueDepth: 0,
        daemonLaunchdState: "unknown",
        watcherLaunchdState: "unknown",
        meetingState: nil,
        meetingId: nil,
        meetingElapsedSeconds: nil,
        meetingWorkerPid: nil
    )
```

- [ ] **Step 2: Add computed property for parsed meeting state**

```swift
// Add to BridgeSnapshot:

    var parsedMeetingState: MeetingLifecycleState {
        guard let raw = meetingState else { return .idle }
        return MeetingLifecycleState(rawValue: raw) ?? .idle
    }
```

- [ ] **Step 3: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add mac-helper/OpenClawHelper/Models/BridgeSnapshot.swift
git commit -m "feat(meeting-ui): extend BridgeSnapshot with meeting state fields"
```

---

## Task 3: MeetingDetectorService

**Files:**
- Create: `mac-helper/OpenClawHelper/Services/MeetingDetectorService.swift`

CoreAudio device listener + NSWorkspace app scanning. Adapted from OpenOats' `MeetingDetector`.

- [ ] **Step 1: Create MeetingDetectorService.swift**

```swift
// mac-helper/OpenClawHelper/Services/MeetingDetectorService.swift
import Combine
import CoreAudio
import AppKit

/// Detects active meetings by monitoring microphone usage and meeting app presence.
/// Adapted from OpenOats' MeetingDetector — filtered to Zoom + Google Meet only.
@MainActor
final class MeetingDetectorService: ObservableObject {
    @Published private(set) var isMeetingDetected: Bool = false
    @Published private(set) var detectedApp: String? = nil  // "zoom" or "google-meet"

    private var micListenerBlock: AudioObjectPropertyListenerBlock?
    private var debounceTask: Task<Void, Never>?
    private var pollTimer: Timer?

    private let debounceSeconds: TimeInterval = 5.0
    private let silenceTimeoutSeconds: TimeInterval = 60.0
    private var micActiveSince: Date?
    private var micSilentSince: Date?

    func startMonitoring() {
        listenToMicrophoneState()
        startAppPolling()
    }

    func stopMonitoring() {
        removeAudioListener()
        pollTimer?.invalidate()
        pollTimer = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - CoreAudio Microphone Listener

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
        // Cleanup handled by invalidation; block reference is released
        micListenerBlock = nil
    }

    // MARK: - App Scanning

    private func startAppPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scanForMeetingApps()
            }
        }
    }

    private func scanForMeetingApps() {
        let apps = NSWorkspace.shared.runningApplications

        // Check for Zoom
        if apps.contains(where: { $0.bundleIdentifier == "us.zoom.xos" }) {
            if isZoomInMeeting() {
                detectedApp = "zoom"
                return
            }
        }

        // Check for Google Meet in Chrome
        if apps.contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
            if isChromeOnGoogleMeet() {
                detectedApp = "google-meet"
                return
            }
        }

        detectedApp = nil
    }

    /// Check for Zoom window title containing "Zoom Meeting" (not lobby/settings)
    private func isZoomInMeeting() -> Bool {
        // Use CGWindowListCopyWindowInfo to check Zoom window titles
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

    /// Check for Chrome with "meet.google.com" in window title
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

    // MARK: - Debounce Logic

    /// 5-second debounce after mic goes active + meeting app detected
    private func debounceMeetingCheck() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.micActiveSince != nil && self.detectedApp != nil {
                self.isMeetingDetected = true
            }
        }
    }

    /// 60-second silence timeout + meeting app no longer foregrounded
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
```

- [ ] **Step 2: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Services/MeetingDetectorService.swift
git commit -m "feat(meeting-ui): add MeetingDetectorService with CoreAudio listener and app scanning"
```

---

## Task 4: MeetingWorkerManager

**Files:**
- Create: `mac-helper/OpenClawHelper/Services/MeetingWorkerManager.swift`

Spawns and manages the `claw-meeting` binary as a child process. Handles PID file, crash recovery, and Unix domain socket communication.

- [ ] **Step 1: Create MeetingWorkerManager.swift**

```swift
// mac-helper/OpenClawHelper/Services/MeetingWorkerManager.swift
import Foundation

/// Manages the claw-meeting worker process lifecycle.
/// Spawns via Foundation.Process, monitors for crashes, communicates via Unix domain socket.
@MainActor
final class MeetingWorkerManager: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var workerPid: Int32? = nil

    private var process: Process?
    private var monitorTask: Task<Void, Never>?

    private let binaryPath: String
    private let pidPath: String
    private let socketPath: String

    init(
        binaryPath: String? = nil,
        pidPath: String = "\(NSHomeDirectory())/.context-bridge/meeting-worker.pid",
        socketPath: String = "\(NSHomeDirectory())/.context-bridge/meeting-worker.sock"
    ) {
        // Default: look for claw-meeting in the app bundle
        self.binaryPath = binaryPath ?? Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("claw-meeting").path
            ?? "/usr/local/bin/claw-meeting"
        self.pidPath = pidPath
        self.socketPath = socketPath
    }

    /// Start the claw-meeting worker for a given meeting ID.
    func startWorker(meetingId: String) throws {
        guard !isRunning else { return }

        // Check for orphaned worker from a previous crash
        cleanupOrphanedWorker()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["--run", meetingId]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle(forWritingAtPath: "/tmp/claw-meeting-error.log")
            ?? FileHandle.nullDevice

        try proc.run()
        process = proc
        workerPid = proc.processIdentifier
        isRunning = true

        // Write PID file
        try String(proc.processIdentifier).write(
            toFile: pidPath, atomically: true, encoding: .utf8
        )

        // Monitor for unexpected termination
        startMonitoring(meetingId: meetingId)
    }

    /// Send stop signal via Unix domain socket, then wait for graceful exit.
    func stopWorker() {
        sendSocketCommand("stop")

        // Give it 10 seconds to finalize, then force kill
        Task {
            try? await Task.sleep(for: .seconds(10))
            if self.isRunning {
                self.forceKill()
            }
        }
    }

    /// Send pause signal to the worker.
    func pauseWorker() {
        sendSocketCommand("pause")
    }

    /// Query worker status via socket.
    func queryStatus() -> String? {
        return sendSocketCommandWithResponse("status")
    }

    /// On launch, check for PID file from a previous crash.
    /// Either reattach or kill the orphaned process.
    func cleanupOrphanedWorker() {
        guard let pidString = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidString) else { return }

        // Check if process is still running
        if kill(pid, 0) == 0 {
            // Process exists — kill it. We can't reattach a Foundation.Process.
            kill(pid, SIGTERM)
            // Wait briefly for cleanup
            usleep(500_000)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }

        // Clean up PID file
        try? FileManager.default.removeItem(atPath: pidPath)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Private

    private func startMonitoring(meetingId: String) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let proc = self?.process else { return }
            proc.waitUntilExit()

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                let exitCode = proc.terminationStatus

                if exitCode != 0 && self.isRunning {
                    // Crash during recording — attempt restart
                    try? self.startWorker(meetingId: meetingId)
                } else {
                    self.isRunning = false
                    self.workerPid = nil
                    self.process = nil
                    try? FileManager.default.removeItem(atPath: self.pidPath)
                }
            }
        }
    }

    private func forceKill() {
        if let pid = process?.processIdentifier {
            kill(pid, SIGKILL)
        }
        process = nil
        isRunning = false
        workerPid = nil
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// Send a command to the worker via Unix domain socket.
    private func sendSocketCommand(_ command: String) {
        let _ = sendSocketCommandWithResponse(command)
    }

    /// Send a command and return the response string.
    private func sendSocketCommandWithResponse(_ command: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        command.utf8CString.withUnsafeBufferPointer { buf in
            _ = write(fd, buf.baseAddress, command.utf8.count)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return nil }
        return String(bytes: buffer[0..<bytesRead], encoding: .utf8)
    }
}
```

- [ ] **Step 2: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Services/MeetingWorkerManager.swift
git commit -m "feat(meeting-ui): add MeetingWorkerManager for claw-meeting process lifecycle"
```

---

## Task 5: BriefingCacheService

**Files:**
- Create: `mac-helper/OpenClawHelper/Services/BriefingCacheService.swift`

Loads pre-loaded briefing packages from `~/.context-bridge/meeting-briefing/<meeting_id>.json`, watches the transcript buffer for keyword matches, and fires notifications.

- [ ] **Step 1: Create BriefingCacheService.swift**

```swift
// mac-helper/OpenClawHelper/Services/BriefingCacheService.swift
import Foundation
import Combine

/// Loads JC's briefing packages and matches live transcript against card keywords.
@MainActor
final class BriefingCacheService: ObservableObject {
    @Published private(set) var currentBriefing: BriefingPackage?
    @Published private(set) var activeNotifications: [MeetingNotification] = []
    @Published private(set) var firedCards: Set<String> = []  // card titles already shown

    private let briefingDir: String
    private let bufferPath: String
    private var bufferWatcherTask: Task<Void, Never>?
    private var dismissTimer: Timer?

    /// Deduplication: same card won't fire twice within this window
    private let deduplicationWindow: TimeInterval = 300.0  // 5 minutes
    private var cardLastFired: [String: Date] = [:]

    init(
        briefingDir: String = "\(NSHomeDirectory())/.context-bridge/meeting-briefing",
        bufferPath: String = "\(NSHomeDirectory())/.context-bridge/meeting-buffer.jsonl"
    ) {
        self.briefingDir = briefingDir
        self.bufferPath = bufferPath
    }

    /// Load a briefing package for a given meeting ID.
    func loadBriefing(meetingId: String) {
        let path = "\(briefingDir)/\(meetingId).json"
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let briefing = try? JSONDecoder().decode(BriefingPackage.self, from: data) else {
            // Try loading the most recent briefing as fallback
            loadMostRecentBriefing()
            return
        }
        currentBriefing = briefing
    }

    /// Start watching the buffer for new transcript segments.
    func startBufferWatch() {
        bufferWatcherTask?.cancel()
        bufferWatcherTask = Task { [weak self] in
            guard let self else { return }
            var lastOffset: UInt64 = 0

            // If file exists, start from current end
            if let attrs = try? FileManager.default.attributesOfItem(atPath: self.bufferPath),
               let size = attrs[.size] as? UInt64 {
                lastOffset = size
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))  // Poll every 500ms
                guard !Task.isCancelled else { break }

                guard let handle = FileHandle(forReadingAtPath: self.bufferPath) else { continue }
                defer { handle.closeFile() }

                let fileSize = handle.seekToEndOfFile()
                guard fileSize > lastOffset else { continue }

                handle.seek(toFileOffset: lastOffset)
                let newData = handle.readDataToEndOfFile()
                lastOffset = fileSize

                guard let text = String(data: newData, encoding: .utf8) else { continue }
                let lines = text.split(separator: "\n")

                for line in lines {
                    self.processTranscriptLine(String(line))
                }
            }
        }

        // Auto-dismiss timer
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneExpiredNotifications()
            }
        }
    }

    /// Stop watching the buffer.
    func stopBufferWatch() {
        bufferWatcherTask?.cancel()
        bufferWatcherTask = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    /// Pin a notification (stops its countdown).
    func pinNotification(_ id: UUID) {
        if let index = activeNotifications.firstIndex(where: { $0.id == id }) {
            activeNotifications[index].isPinned = true
        }
    }

    /// Dismiss a specific notification.
    func dismissNotification(_ id: UUID) {
        activeNotifications.removeAll { $0.id == id }
    }

    /// Reset state for a new meeting.
    func reset() {
        currentBriefing = nil
        activeNotifications = []
        firedCards = []
        cardLastFired = [:]
        stopBufferWatch()
    }

    // MARK: - Private

    private func processTranscriptLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        // Parse as a generic JSON to check the "type" field
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "transcript",
              let text = json["text"] as? String else { return }

        matchKeywords(transcriptText: text)
    }

    private func matchKeywords(transcriptText: String) {
        guard let briefing = currentBriefing else { return }

        for card in briefing.cards {
            // Skip if this card was fired recently
            if let lastFired = cardLastFired[card.title],
               Date().timeIntervalSince(lastFired) < deduplicationWindow {
                continue
            }

            if card.matches(transcriptText: transcriptText) {
                // Find which keyword matched for the notification
                let matchedKeyword = card.triggerKeywords.first { kw in
                    transcriptText.lowercased().contains(kw.lowercased())
                } ?? ""

                let notification = MeetingNotification(card: card, triggerKeyword: matchedKeyword)
                activeNotifications.append(notification)
                firedCards.insert(card.title)
                cardLastFired[card.title] = Date()
            }
        }
    }

    private func pruneExpiredNotifications() {
        activeNotifications.removeAll { $0.isExpired }
    }

    private func loadMostRecentBriefing() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: briefingDir) else { return }
        let jsonFiles = files.filter { $0.hasSuffix(".json") }.sorted().reversed()
        guard let mostRecent = jsonFiles.first else { return }

        let path = "\(briefingDir)/\(mostRecent)"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let briefing = try? JSONDecoder().decode(BriefingPackage.self, from: data) else { return }
        currentBriefing = briefing
    }
}
```

- [ ] **Step 2: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Services/BriefingCacheService.swift
git commit -m "feat(meeting-ui): add BriefingCacheService with keyword matching and notifications"
```

---

## Task 6: MeetingSessionManager (Lifecycle State Machine)

**Files:**
- Create: `mac-helper/OpenClawHelper/Services/MeetingSessionManager.swift`

The orchestrator that ties detection, worker management, and briefing together. Implements the lifecycle: idle -> preparing -> recording -> finalizing -> idle.

- [ ] **Step 1: Create MeetingSessionManager.swift**

```swift
// mac-helper/OpenClawHelper/Services/MeetingSessionManager.swift
import Foundation
import Combine

/// Orchestrates the meeting lifecycle.
/// State machine: idle → preparing → recording → finalizing → idle.
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

    init(
        detector: MeetingDetectorService = MeetingDetectorService(),
        workerManager: MeetingWorkerManager = MeetingWorkerManager(),
        briefingCache: BriefingCacheService = BriefingCacheService()
    ) {
        self.detector = detector
        self.workerManager = workerManager
        self.briefingCache = briefingCache

        setupAutoDetection()
    }

    /// Manual start — disables auto-stop.
    func startMeeting(meetingId: String? = nil, app: String? = nil) {
        guard state == .idle else { return }
        manuallyStarted = true
        let id = meetingId ?? generateMeetingId(app: app)
        beginPreparing(meetingId: id, app: app)
    }

    /// Manual stop.
    func stopMeeting() {
        guard state == .recording || state == .preparing else { return }
        beginFinalizing()
    }

    /// Cancel finalization (keeps streaming transcript, discards batch results).
    func cancelFinalization() {
        guard state == .finalizing else { return }
        transitionToIdle()
    }

    /// Cleanup on app quit.
    func shutdown() {
        detector.stopMonitoring()
        if state != .idle {
            workerManager.stopWorker()
        }
        briefingCache.reset()
    }

    // MARK: - State Machine

    private func beginPreparing(meetingId: String, app: String?) {
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

        // Load briefing
        briefingCache.loadBriefing(meetingId: meetingId)
        if briefingCache.currentBriefing != nil {
            sessionInfo?.briefingLoaded = true
        }

        // Spawn worker
        do {
            try workerManager.startWorker(meetingId: meetingId)
            sessionInfo?.workerPid = workerManager.workerPid
            transitionToRecording()
        } catch {
            // Worker failed to start — fall back to idle
            transitionToIdle()
        }
    }

    private func transitionToRecording() {
        state = .recording
        elapsedSeconds = 0

        // Start buffer watching for keyword matches
        briefingCache.startBufferWatch()

        // Start elapsed timer
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

        // Tell worker to stop (it will run batch transcription during finalization)
        workerManager.stopWorker()

        // Monitor worker exit to transition to idle
        Task {
            // Wait for worker to finish (max 120 seconds for batch processing)
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
        sessionInfo = nil
        elapsedSeconds = 0
        manuallyStarted = false
        briefingCache.reset()
    }

    // MARK: - Auto-Detection

    private func setupAutoDetection() {
        detector.startMonitoring()

        detector.$isMeetingDetected
            .removeDuplicates()
            .sink { [weak self] detected in
                guard let self else { return }
                if detected && self.state == .idle {
                    let app = self.detector.detectedApp
                    let id = self.generateMeetingId(app: app)
                    self.beginPreparing(meetingId: id, app: app)
                } else if !detected && self.state == .recording && !self.manuallyStarted {
                    // Auto-stop only if not manually started
                    self.beginFinalizing()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Helpers

    private func generateMeetingId(app: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let appSuffix = app ?? "unknown"
        return "\(timestamp)-\(appSuffix)"
    }

    /// Formatted elapsed time string (e.g., "12:34")
    var formattedElapsed: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
```

- [ ] **Step 2: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Services/MeetingSessionManager.swift
git commit -m "feat(meeting-ui): add MeetingSessionManager lifecycle state machine"
```

---

## Task 7: MeetingViewModel

**Files:**
- Create: `mac-helper/OpenClawHelper/ViewModels/MeetingViewModel.swift`

Binds meeting state to all UI components. Thin layer over MeetingSessionManager.

- [ ] **Step 1: Create MeetingViewModel.swift**

```swift
// mac-helper/OpenClawHelper/ViewModels/MeetingViewModel.swift
import SwiftUI
import Combine

@MainActor
final class MeetingViewModel: ObservableObject {
    @Published var showSidebar: Bool = false
    @Published var showOverlay: Bool = true

    let sessionManager: MeetingSessionManager

    private var cancellables = Set<AnyCancellable>()

    init(sessionManager: MeetingSessionManager = MeetingSessionManager()) {
        self.sessionManager = sessionManager

        // Forward changes from session manager
        sessionManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // Forward changes from briefing cache
        sessionManager.briefingCache.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    // MARK: - Convenience Accessors

    var state: MeetingLifecycleState { sessionManager.state }
    var isActive: Bool { state.isActive }
    var meetingId: String? { sessionManager.sessionInfo?.meetingId }
    var formattedElapsed: String { sessionManager.formattedElapsed }
    var briefing: BriefingPackage? { sessionManager.briefingCache.currentBriefing }
    var notifications: [MeetingNotification] { sessionManager.briefingCache.activeNotifications }
    var firedCardCount: Int { sessionManager.briefingCache.firedCards.count }

    // MARK: - Actions

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

// MARK: - Preview Support

extension MeetingViewModel {
    static var preview: MeetingViewModel {
        MeetingViewModel()
    }
}
```

- [ ] **Step 2: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/ViewModels/MeetingViewModel.swift
git commit -m "feat(meeting-ui): add MeetingViewModel binding meeting state to UI"
```

---

## Task 8: MeetingStatusView (Menu Bar Popover Section)

**Files:**
- Create: `mac-helper/OpenClawHelper/Views/MeetingStatusView.swift`

New section in the menu bar popover showing meeting state, elapsed time, and Start/Stop/Sidebar buttons.

- [ ] **Step 1: Create MeetingStatusView.swift**

```swift
// mac-helper/OpenClawHelper/Views/MeetingStatusView.swift
import SwiftUI

struct MeetingStatusView: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: viewModel.state.systemImage)
                    .font(.title3)
                    .foregroundStyle(stateColor)
                    .symbolEffect(.pulse, isActive: viewModel.state == .recording)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting: \(viewModel.state.displayLabel)")
                        .font(DarkUtilityGlass.compactBody)

                    if viewModel.isActive {
                        HStack(spacing: 4) {
                            Text(viewModel.formattedElapsed)
                                .font(DarkUtilityGlass.monoCaption)
                                .foregroundStyle(.secondary)

                            if let app = viewModel.sessionManager.sessionInfo?.app {
                                Text("(\(app))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if viewModel.firedCardCount > 0 {
                                Text("\(viewModel.firedCardCount) cards")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.blue.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }

                Spacer()

                meetingActions
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var meetingActions: some View {
        switch viewModel.state {
        case .idle:
            Button(action: { viewModel.startMeeting() }) {
                Label("Start", systemImage: "mic.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.green)

        case .preparing:
            ProgressView()
                .controlSize(.small)

        case .recording:
            HStack(spacing: 6) {
                Button(action: { viewModel.toggleSidebar() }) {
                    Image(systemName: "sidebar.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button(action: { viewModel.stopMeeting() }) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

        case .finalizing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Button(action: { viewModel.cancelFinalization() }) {
                    Text("Cancel")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var stateColor: Color {
        switch viewModel.state {
        case .idle:       return .secondary
        case .preparing:  return .orange
        case .recording:  return .red
        case .finalizing: return .blue
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Views/MeetingStatusView.swift
git commit -m "feat(meeting-ui): add MeetingStatusView for menu bar popover"
```

---

## Task 9: MeetingOverlayPanel + NotificationCardView

**Files:**
- Create: `mac-helper/OpenClawHelper/Views/MeetingOverlayPanel.swift`
- Create: `mac-helper/OpenClawHelper/Views/NotificationCardView.swift`

NSPanel with `sharingType = .none` (invisible to screen share). Hosts slide-in notification cards.

- [ ] **Step 1: Create MeetingOverlayPanel.swift**

```swift
// mac-helper/OpenClawHelper/Views/MeetingOverlayPanel.swift
import SwiftUI
import AppKit

/// NSPanel wrapper that is invisible to screen sharing.
/// Floats above all windows, click-through except for card content.
final class MeetingOverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Invisible to screen share
        sharingType = .none

        // Panel behaviour
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position: top-right of main screen
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

    /// Show the panel with notifications content.
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

/// SwiftUI container for overlay notifications
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
```

- [ ] **Step 2: Create NotificationCardView.swift**

```swift
// mac-helper/OpenClawHelper/Views/NotificationCardView.swift
import SwiftUI

struct NotificationCardView: View {
    let notification: MeetingNotification
    let onPin: () -> Void
    let onDismiss: () -> Void

    @State private var remainingFraction: Double = 1.0
    private let totalDuration: TimeInterval = 8.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + title
            HStack {
                Image(systemName: categoryIcon)
                    .foregroundStyle(priorityColor)
                Text(notification.card.title)
                    .font(.callout.bold())
                    .foregroundStyle(.primary)
                Spacer()
                if notification.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            // Body text
            Text(notification.card.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)

            // Countdown bar + dismiss controls
            HStack {
                Spacer()
                if !notification.isPinned {
                    Text("\(Int(notification.remainingSeconds))s")
                        .font(DarkUtilityGlass.monoCaption)
                        .foregroundStyle(.tertiary)
                }
                // Countdown progress bar
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.15))
                        .frame(width: geo.size.width)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(priorityColor.opacity(0.6))
                                .frame(width: geo.size.width * remainingFraction)
                        }
                }
                .frame(width: 60, height: 4)
            }
        }
        .padding(14)
        .glassCard()
        .onTapGesture {
            onPin()
        }
        .contextMenu {
            Button("Dismiss") { onDismiss() }
            if !notification.isPinned {
                Button("Pin") { onPin() }
            }
        }
        .onAppear {
            startCountdown()
        }
    }

    private var categoryIcon: String {
        switch notification.card.category {
        case "behavioural": return "brain.head.profile"
        case "data":        return "chart.bar.fill"
        case "context":     return "doc.text.fill"
        default:            return "lightbulb.fill"
        }
    }

    private var priorityColor: Color {
        switch notification.card.priority {
        case "high":   return .orange
        case "medium": return .blue
        case "low":    return .secondary
        default:       return .blue
        }
    }

    private func startCountdown() {
        guard !notification.isPinned else {
            remainingFraction = 1.0
            return
        }
        withAnimation(.linear(duration: notification.remainingSeconds)) {
            remainingFraction = 0.0
        }
    }
}
```

- [ ] **Step 3: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add mac-helper/OpenClawHelper/Views/MeetingOverlayPanel.swift \
        mac-helper/OpenClawHelper/Views/NotificationCardView.swift
git commit -m "feat(meeting-ui): add MeetingOverlayPanel and NotificationCardView"
```

---

## Task 10: MeetingSidebarView

**Files:**
- Create: `mac-helper/OpenClawHelper/Views/MeetingSidebarView.swift`

Full-height docked sidebar panel. Shows all briefing cards, participant profiles, talking points, and live transcript. Also an NSPanel with `sharingType = .none`.

- [ ] **Step 1: Create MeetingSidebarView.swift**

```swift
// mac-helper/OpenClawHelper/Views/MeetingSidebarView.swift
import SwiftUI
import AppKit

/// Full-height sidebar panel docked to the right edge of the screen.
/// Invisible to screen share (NSPanel.sharingType = .none).
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

/// SwiftUI content for the sidebar.
struct MeetingSidebarView: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            sidebarHeader

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Talking points
                    if let points = viewModel.briefing?.talkingPoints, !points.isEmpty {
                        talkingPointsSection(points)
                    }

                    // Participant profiles
                    if let profiles = viewModel.briefing?.participantProfiles, !profiles.isEmpty {
                        participantProfilesSection(profiles)
                    }

                    // All briefing cards
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

    // MARK: - Sections

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
                .foregroundStyle(.primary)

            ForEach(points, id: \.self) { point in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    Text(point)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private func participantProfilesSection(_ profiles: [String: ParticipantProfile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Participants", systemImage: "person.2.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)

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
                .foregroundStyle(.primary)

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
```

- [ ] **Step 2: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Views/MeetingSidebarView.swift
git commit -m "feat(meeting-ui): add MeetingSidebarView and MeetingSidebarPanel"
```

---

## Task 11: Wire Into AppModel + MenuBarPopoverView

**Files:**
- Modify: `mac-helper/OpenClawHelper/AppModel.swift`
- Modify: `mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift`

Connect the meeting system to the app and add the meeting section to the popover.

- [ ] **Step 1: Add MeetingViewModel to AppModel**

In `AppModel.swift`, add the meeting view model and forward its changes:

```swift
// After existing properties:
let meetingViewModel: MeetingViewModel

// In init(), after existing setup:
self.meetingViewModel = MeetingViewModel()

// Add another objectWillChange forwarding:
meetingViewModel.objectWillChange.sink { [weak self] _ in
    self?.objectWillChange.send()
}.store(in: &cancellables)
```

Update `menuBarSymbol` to reflect meeting state:

```swift
var menuBarSymbol: String {
    if meetingViewModel.state == .recording {
        return "mic.fill"
    }
    return menuBarViewModel.snapshot.trackingState.menuBarSymbol
}
```

- [ ] **Step 2: Add MeetingStatusView to MenuBarPopoverView**

In `MenuBarPopoverView.swift`, add the meeting section between `HealthStripView` and `QuickActionsGrid`. The viewModel needs access to `meetingViewModel`, so pass it through:

First, add the meeting view model as a property:

```swift
struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @ObservedObject var meetingViewModel: MeetingViewModel
    @Environment(\.openWindow) private var openWindow
```

Then add the meeting section in the body, between `HealthStripView` and `QuickActionsGrid`:

```swift
            HealthStripView(snapshot: viewModel.snapshot)

            // Meeting section
            MeetingStatusView(viewModel: meetingViewModel)

            QuickActionsGrid(viewModel: viewModel)
```

- [ ] **Step 3: Update OpenClawHelperApp.swift**

Pass the meeting view model to MenuBarPopoverView:

```swift
MenuBarPopoverView(
    viewModel: appModel.menuBarViewModel,
    meetingViewModel: appModel.meetingViewModel
)
```

- [ ] **Step 4: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add mac-helper/OpenClawHelper/AppModel.swift \
        mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift \
        mac-helper/OpenClawHelper/OpenClawHelperApp.swift
git commit -m "feat(meeting-ui): wire MeetingViewModel into AppModel and popover"
```

---

## Task 12: Overlay Panel Window Management

**Files:**
- Modify: `mac-helper/OpenClawHelper/ViewModels/MeetingViewModel.swift`

Add NSPanel lifecycle management to MeetingViewModel. The overlay panel and sidebar panel need to be shown/hidden based on meeting state.

- [ ] **Step 1: Add panel management to MeetingViewModel**

Add panel properties and state-driven panel management:

```swift
// Add properties to MeetingViewModel:
    private var overlayPanel: MeetingOverlayPanel?
    private var sidebarPanel: MeetingSidebarPanel?

// Add method to show/hide overlay based on state:
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
```

Add a Combine subscriber in `init` to call `updatePanels()` when state changes:

```swift
// In init(), after existing subscribers:
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
```

- [ ] **Step 2: Build to verify compilation**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/ViewModels/MeetingViewModel.swift
git commit -m "feat(meeting-ui): add overlay and sidebar panel lifecycle management"
```

---

## Task 13: helperctl Meeting Actions

**Files:**
- Modify: `mac-daemon/context-helperctl.sh`

Add `meeting-start`, `meeting-stop`, `meeting-status` actions to the existing helperctl script. These commands write control files that MeetingSessionManager reads, or query state from the meeting worker.

- [ ] **Step 1: Add meeting-status function**

Add after the existing `do_mark_question_seen` function, before the main dispatch block:

```bash
# ---------------------------------------------------------------------------
# meeting-status  – JSON snapshot of current meeting state
# ---------------------------------------------------------------------------
do_meeting_status() {
  python3 - <<'PY'
import json, os

home = os.path.expanduser("~/.context-bridge")
pid_path = os.path.join(home, "meeting-worker.pid")
state_path = os.path.join(home, "meeting-state.json")

result = {
    "state": "idle",
    "meeting_id": None,
    "elapsed_seconds": 0,
    "worker_pid": None,
    "transcript_segments": 0,
    "screenshots_taken": 0,
    "briefing_loaded": False,
    "cards_surfaced": 0
}

# Check for active worker
if os.path.exists(pid_path):
    try:
        pid = int(open(pid_path).read().strip())
        # Check if process is running
        os.kill(pid, 0)
        result["worker_pid"] = pid
    except (ValueError, ProcessLookupError, PermissionError):
        pass

# Check for state file (written by claw-meeting worker)
if os.path.exists(state_path):
    try:
        state = json.load(open(state_path))
        result.update(state)
    except (json.JSONDecodeError, IOError):
        pass

# If worker is running but no state file, it's preparing
if result["worker_pid"] and result["state"] == "idle":
    result["state"] = "preparing"

print(json.dumps({"meeting": result}))
PY
}
```

- [ ] **Step 2: Add meeting-start and meeting-stop functions**

```bash
# ---------------------------------------------------------------------------
# meeting-start [meeting-id]  – trigger meeting start
# ---------------------------------------------------------------------------
do_meeting_start() {
  local meeting_id="${1:-}"
  local trigger_file
  trigger_file="$(cb_dir)/meeting-start-trigger"

  if [ -n "$meeting_id" ]; then
    echo "$meeting_id" > "$trigger_file"
  else
    echo "auto-$(date +%Y%m%d-%H%M%S)" > "$trigger_file"
  fi
  echo '{"status":"triggered"}'
}

# ---------------------------------------------------------------------------
# meeting-stop  – trigger meeting stop
# ---------------------------------------------------------------------------
do_meeting_stop() {
  local trigger_file
  trigger_file="$(cb_dir)/meeting-stop-trigger"
  touch "$trigger_file"
  echo '{"status":"triggered"}'
}
```

- [ ] **Step 3: Add to main dispatch and update usage string**

Add to the case statement:

```bash
  meeting-status)   do_meeting_status ;;
  meeting-start)    do_meeting_start "$@" ;;
  meeting-stop)     do_meeting_stop ;;
```

Update the error/usage line:

```bash
  *)
    echo '{"error":"unknown command","usage":"status|pause|resume|sensitive|restart-daemon|restart-watcher|purge-local|queue-handoff|list-handoffs|dashboard|mark-question-seen|privacy-rules|meeting-start|meeting-stop|meeting-status"}' >&2
    exit 1
    ;;
```

- [ ] **Step 4: Add meeting state to status_json**

In the `status_json()` function, extend the Python script to include meeting state in the snapshot. Add before `print(json.dumps(snapshot))`:

```python
# Meeting state
meeting_state = "idle"
meeting_id = None
meeting_elapsed = None
meeting_pid = None
pid_path = os.path.join(home, "meeting-worker.pid")
state_path = os.path.join(home, "meeting-state.json")
if os.path.exists(pid_path):
    try:
        pid = int(open(pid_path).read().strip())
        os.kill(pid, 0)
        meeting_pid = pid
        meeting_state = "preparing"
    except (ValueError, ProcessLookupError, PermissionError):
        pass
if os.path.exists(state_path):
    try:
        ms = json.load(open(state_path))
        meeting_state = ms.get("state", meeting_state)
        meeting_id = ms.get("meeting_id")
        meeting_elapsed = ms.get("elapsed_seconds")
    except (json.JSONDecodeError, IOError):
        pass

snapshot["meetingState"] = meeting_state
snapshot["meetingId"] = meeting_id
snapshot["meetingElapsedSeconds"] = meeting_elapsed
snapshot["meetingWorkerPid"] = meeting_pid
```

- [ ] **Step 5: Test helperctl meeting commands**

```bash
# Test meeting-status (should return idle)
bash mac-daemon/context-helperctl.sh meeting-status

# Test meeting-start
bash mac-daemon/context-helperctl.sh meeting-start test-meeting-001

# Test meeting-stop
bash mac-daemon/context-helperctl.sh meeting-stop

# Test status includes meeting fields
bash mac-daemon/context-helperctl.sh status | python3 -m json.tool
```

Expected: All commands return valid JSON, status includes meetingState field.

- [ ] **Step 6: Commit**

```bash
git add mac-daemon/context-helperctl.sh
git commit -m "feat(meeting-ui): add meeting-start, meeting-stop, meeting-status to helperctl"
```

---

## Task 14: Integration Test — End-to-End Mock Flow

**Files:**
- No new files. This task tests the integration by running the full app with mock data.

- [ ] **Step 1: Create a test briefing package**

```bash
mkdir -p ~/.context-bridge/meeting-briefing
cat > ~/.context-bridge/meeting-briefing/test-meeting-001.json << 'EOF'
{
  "meeting_id": "test-meeting-001",
  "attendees": ["david_rotman", "liz_chen"],
  "topic": "Sonopeace Q2 pricing",
  "cards": [
    {
      "trigger_keywords": ["cash flow", "budget", "afford", "expensive"],
      "title": "David + cash flow",
      "body": "David panicked at similar numbers in January. Recovered in 48hrs. Don't offer concessions yet.",
      "priority": "high",
      "category": "behavioural"
    },
    {
      "trigger_keywords": ["break even", "breakeven", "ROI", "payback"],
      "title": "Break-even numbers",
      "body": "18 months at 500 units. He's seen this before. Reference the deck from Feb 12.",
      "priority": "medium",
      "category": "data"
    }
  ],
  "participant_profiles": {
    "david_rotman": {
      "decision_style": "needs_time_to_process",
      "stress_triggers": ["large_numbers", "timeline_pressure"],
      "framing_advice": "Phased numbers, not lump sums"
    }
  },
  "talking_points": [
    "Confirm Q3 vs Q4 timeline preference",
    "Get commitment on pilot scope"
  ]
}
EOF
```

- [ ] **Step 2: Simulate a transcript buffer with keyword matches**

```bash
cat > ~/.context-bridge/meeting-buffer.jsonl << 'EOF'
{"type":"transcript","meeting_id":"test-meeting-001","timestamp":12.5,"speaker":"speaker_1","text":"So let me talk about the budget for this quarter","confidence":0.93,"words":[],"is_final":true}
{"type":"transcript","meeting_id":"test-meeting-001","timestamp":45.2,"speaker":"speaker_2","text":"What about the break even timeline?","confidence":0.89,"words":[],"is_final":true}
EOF
```

- [ ] **Step 3: Build and run the app to verify UI**

```bash
cd mac-helper && xcodebuild -scheme ClawRelay -configuration Debug build 2>&1 | tail -5
```

Manual verification checklist:
1. Menu bar popover shows meeting section with "Meeting: Idle" and Start button
2. Start button transitions to Preparing then Recording
3. (Without claw-meeting binary, worker start will fail — transitions back to idle. This is expected.)
4. Briefing package loads from test file
5. helperctl status includes meetingState field

- [ ] **Step 4: Commit (no code changes — test artifacts only, don't commit)**

Cleanup test data:

```bash
rm -f ~/.context-bridge/meeting-buffer.jsonl
rm -rf ~/.context-bridge/meeting-briefing/test-meeting-001.json
```

---

## Summary

| Task | Files | What It Does |
|---|---|---|
| 1 | 3 new models | MeetingState, BriefingPackage, MeetingNotification data types |
| 2 | 1 modified model | BridgeSnapshot meeting fields |
| 3 | 1 new service | MeetingDetectorService: CoreAudio + NSWorkspace |
| 4 | 1 new service | MeetingWorkerManager: Process lifecycle + socket comms |
| 5 | 1 new service | BriefingCacheService: keyword matching + notifications |
| 6 | 1 new service | MeetingSessionManager: lifecycle state machine |
| 7 | 1 new view model | MeetingViewModel: binds state to UI |
| 8 | 1 new view | MeetingStatusView: menu bar popover section |
| 9 | 2 new views | MeetingOverlayPanel + NotificationCardView |
| 10 | 1 new view | MeetingSidebarView + MeetingSidebarPanel |
| 11 | 3 modified files | Wire into AppModel, popover, and app entry point |
| 12 | 1 modified view model | Panel lifecycle management |
| 13 | 1 modified script | helperctl meeting-start/stop/status |
| 14 | 0 | Integration test with mock data |

**Total:** 13 new files, 5 modified files, 14 tasks, ~55 steps.

**Estimated time:** ~3-4 hours for an agent executing sequentially.

**Next:** Plan 3 — Server-side meeting processing (meeting-processor.py, database schema, digest integration, Claude Vision batch analysis).

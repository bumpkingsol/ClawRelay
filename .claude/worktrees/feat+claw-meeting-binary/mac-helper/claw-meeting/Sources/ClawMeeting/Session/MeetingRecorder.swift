import AVFoundation
import Foundation

// MARK: - MeetingRecorder
//
// Top-level orchestrator that wires together all meeting-capture components:
//   Audio:   SystemAudioCapture + MicCapture → AudioMixer → LiveTranscriber
//   Visual:  ScreenCapture → FaceAnalyzer → FaceTracker
//   Output:  BufferWriter (JSONL), SessionStore (directories)
//   Control: SocketServer (pause/stop), PauseSensitiveChecker (file-based)
//
// Lifecycle: init → start() → [runs until stop signal] → finalize()

@available(macOS 14.2, *)
final class MeetingRecorder {

    // MARK: - Components

    private let session: MeetingSession
    private let sessionStore: SessionStore
    private let bufferWriter: BufferWriter
    private let socketServer: SocketServer
    private let pauseChecker: PauseSensitiveChecker

    // Audio pipeline
    private let systemCapture: SystemAudioCapture
    private let micCapture: MicCapture
    private let mixer: AudioMixer
    private let liveTranscriber: LiveTranscriber

    // Visual pipeline
    private let screenCapture: ScreenCapture
    private let faceAnalyzer: FaceAnalyzer
    private let faceTracker: FaceTracker

    // Audio file writer
    private var wavWriter: WAVFileWriter?

    // State
    private var shouldStop = false
    private var pauseCheckTimer: DispatchSourceTimer?
    private var audioCapturing = false
    private var screenCapturing = false

    // Keywords that trigger high-frequency screenshots
    private static let triggerKeywords: Set<String> = [
        "price", "cost", "budget", "deadline", "timeline",
        "concern", "problem", "issue", "risk", "decision",
    ]

    // MARK: - Init

    init(meetingId: String) throws {
        let store = SessionStore()
        let paths = try store.createSession(id: meetingId)

        self.sessionStore = store
        self.session = MeetingSession(id: meetingId, paths: paths)
        self.bufferWriter = BufferWriter(path: "\(paths.rootDir)/buffer.jsonl")
        self.socketServer = SocketServer()
        self.pauseChecker = PauseSensitiveChecker()

        self.systemCapture = SystemAudioCapture()
        self.micCapture = MicCapture()
        self.mixer = AudioMixer()
        self.liveTranscriber = LiveTranscriber(meetingId: meetingId)

        self.screenCapture = ScreenCapture(framesDir: paths.framesDir)
        self.faceAnalyzer = FaceAnalyzer()
        self.faceTracker = FaceTracker()
    }

    // MARK: - Run (blocks until stop)

    func run() async throws {
        writePIDFile()
        defer { removePIDFile() }

        try wireAndStart()
        defer { stopAll() }

        log("Meeting recorder started: \(session.id)")

        // Block until shouldStop is signalled
        while !shouldStop {
            try await Task.sleep(for: .milliseconds(200))
        }

        log("Stop signal received, finalizing...")
        try await finalize()

        log("Meeting recorder finished: \(session.id)")
    }

    // MARK: - Wire + Start All Components

    private func wireAndStart() throws {
        // 1. Control socket
        socketServer.onCommand = { [weak self] command in
            self?.handleCommand(command) ?? "{\"error\": \"recorder gone\"}"
        }
        try socketServer.start()

        // 2. Audio pipeline wiring
        systemCapture.onBuffer = { [weak self] buffer in
            self?.mixer.processSystemBuffer(buffer)
        }
        micCapture.onBuffer = { [weak self] buffer in
            self?.mixer.processMicBuffer(buffer)
        }
        mixer.onMixedBuffer = { [weak self] samples in
            self?.handleMixedAudio(samples)
        }

        // 3. Transcription callback
        liveTranscriber.onSegment = { [weak self] segment in
            self?.handleTranscriptSegment(segment)
        }

        // 4. Visual pipeline wiring
        screenCapture.onCapture = { [weak self] url, frameNumber in
            self?.handleScreenCapture(url: url, frameNumber: frameNumber)
        }

        // 5. Start audio capture
        startAudioCapture()

        // 6. Start screen capture
        startScreenCapture()

        // 7. Start pause/sensitive polling
        startPausePolling()
    }

    // MARK: - Audio Capture Control

    private func startAudioCapture() {
        guard !audioCapturing else { return }
        do {
            try systemCapture.start()
        } catch {
            log("Warning: system audio capture failed to start: \(error)")
        }
        do {
            try micCapture.start()
        } catch {
            log("Warning: mic capture failed to start: \(error)")
        }
        audioCapturing = true
    }

    private func stopAudioCapture() {
        guard audioCapturing else { return }
        systemCapture.stop()
        micCapture.stop()
        audioCapturing = false
    }

    // MARK: - Screen Capture Control

    private func startScreenCapture() {
        guard !screenCapturing else { return }
        screenCapture.start()
        screenCapturing = true
    }

    private func stopScreenCapture() {
        guard screenCapturing else { return }
        screenCapture.stop()
        screenCapturing = false
    }

    // MARK: - Audio Handler

    private func handleMixedAudio(_ samples: [Float]) {
        // In sensitive mode, audio still flows but we do NOT write transcript
        // (the onSegment callback checks session state before writing)
        do {
            try liveTranscriber.processAudio(samples)
        } catch {
            log("Warning: processAudio failed: \(error)")
        }
    }

    // MARK: - Transcript Handler

    private func handleTranscriptSegment(_ segment: TranscriptSegment) {
        // Do not write transcript in sensitive mode
        guard session.state != .sensitive else { return }
        guard session.state != .paused else { return }

        do {
            try bufferWriter.writeTranscript(segment)
            session.incrementSegments()
        } catch {
            log("Warning: writeTranscript failed: \(error)")
        }

        // Check for keyword triggers
        checkKeywordTriggers(text: segment.text)
    }

    // MARK: - Screenshot Handler

    private func handleScreenCapture(url: URL, frameNumber: Int) {
        session.incrementFrames()

        // Run face analysis
        do {
            let observations = try faceAnalyzer.analyze(imageURL: url)
            let tracked = faceTracker.trackFaces(observations)

            if !tracked.isEmpty {
                let event = VisualEvent(
                    meetingId: session.id,
                    timestamp: Date().timeIntervalSince1970,
                    alignedTranscriptSegment: session.segmentCount,
                    trigger: "periodic",
                    participants: tracked
                )
                try bufferWriter.writeVisual(event)
            }
        } catch {
            log("Warning: face analysis failed for frame \(frameNumber): \(error)")
        }
    }

    // MARK: - Keyword Trigger

    private func checkKeywordTriggers(text: String) {
        let lower = text.lowercased()
        for keyword in Self.triggerKeywords {
            if lower.contains(keyword) {
                screenCapture.triggerHighFrequency(reason: "keyword:\(keyword)")
                break
            }
        }
    }

    // MARK: - Socket Command Handler

    private func handleCommand(_ command: SocketCommand) -> String {
        switch command {
        case .stop:
            shouldStop = true
            return "{\"status\": \"stopping\"}"

        case .status:
            return session.statusJSON()

        case .pause:
            if session.state == .recording {
                session.transition(to: .paused)
                stopAudioCapture()
                stopScreenCapture()
            }
            return session.statusJSON()

        case .resume:
            if session.state == .paused || session.state == .sensitive {
                session.transition(to: .recording)
                startAudioCapture()
                startScreenCapture()
            }
            return session.statusJSON()

        case .unknown:
            return "{\"error\": \"unknown command\"}"
        }
    }

    // MARK: - Pause/Sensitive Polling

    private func startPausePolling() {
        pauseCheckTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        pauseCheckTimer?.schedule(
            deadline: .now() + Config.pauseCheckInterval,
            repeating: Config.pauseCheckInterval
        )
        pauseCheckTimer?.setEventHandler { [weak self] in
            self?.checkPauseSensitive()
        }
        pauseCheckTimer?.resume()
    }

    private func stopPausePolling() {
        pauseCheckTimer?.cancel()
        pauseCheckTimer = nil
    }

    private func checkPauseSensitive() {
        let wasPaused = session.state == .paused
        let wasSensitive = session.state == .sensitive

        if pauseChecker.isPaused {
            if !wasPaused {
                session.transition(to: .paused)
                stopAudioCapture()
                stopScreenCapture()
                log("Paused: all capture stopped")
            }
        } else if pauseChecker.isSensitive {
            if !wasSensitive {
                session.transition(to: .sensitive)
                // Audio continues but transcript is suppressed (handled in handleTranscriptSegment)
                // Screenshots stop
                stopScreenCapture()
                if !audioCapturing { startAudioCapture() }
                log("Sensitive mode: screenshots stopped, transcript suppressed")
            }
        } else {
            // Neither paused nor sensitive
            if wasPaused || wasSensitive {
                session.transition(to: .recording)
                startAudioCapture()
                startScreenCapture()
                log("Resumed: all capture active")
            }
        }
    }

    // MARK: - Finalize

    private func finalize() async throws {
        session.transition(to: .finalizing)

        // 1. Stop all capture
        stopAll()

        // 2. Stop live transcriber
        _ = try? await liveTranscriber.stop()

        // 3. Run batch transcription + diarisation on the full audio file
        let audioURL = URL(fileURLWithPath: session.paths.audioPath)
        var finalSegments: [TranscriptSegment] = []

        if FileManager.default.fileExists(atPath: session.paths.audioPath) {
            // Batch transcription
            do {
                let batchTranscriber = BatchTranscriber()
                try await batchTranscriber.prepare()
                finalSegments = try await batchTranscriber.transcribe(
                    url: audioURL,
                    meetingId: session.id
                )
                await batchTranscriber.cleanup()
                log("Batch transcription complete: \(finalSegments.count) segment(s)")
            } catch {
                log("Warning: batch transcription failed: \(error)")
            }

            // Diarisation
            do {
                let diarisationRunner = DiarisationRunner()
                try await diarisationRunner.prepare()
                let speakers = try await diarisationRunner.diarise(url: audioURL)
                if !speakers.isEmpty {
                    finalSegments = DiarisationRunner.assignSpeakers(
                        to: finalSegments,
                        from: speakers
                    )
                    log("Diarisation complete: \(speakers.count) speaker segment(s)")
                }
            } catch {
                log("Warning: diarisation failed: \(error)")
            }
        } else {
            log("No audio file found at \(session.paths.audioPath), skipping batch processing")
        }

        // 4. Write final transcript.json
        if !finalSegments.isEmpty {
            let transcriptPath = "\(session.paths.rootDir)/transcript.json"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(finalSegments)
            try data.write(to: URL(fileURLWithPath: transcriptPath))
            log("Final transcript written to \(transcriptPath)")
        }

        // 5. Cleanup
        try? sessionStore.cleanupOldSessions()

        session.transition(to: .completed)
        log("Session \(session.id) completed")
    }

    // MARK: - Stop All

    private func stopAll() {
        stopPausePolling()
        stopAudioCapture()
        stopScreenCapture()
        socketServer.stop()
    }

    // MARK: - PID File

    private func writePIDFile() {
        let pid = ProcessInfo.processInfo.processIdentifier
        try? "\(pid)".write(
            toFile: Config.pidPath,
            atomically: true,
            encoding: .utf8
        )
    }

    private func removePIDFile() {
        try? FileManager.default.removeItem(atPath: Config.pidPath)
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: Date())
        fputs("[\(ts)] \(message)\n", stderr)
    }
}

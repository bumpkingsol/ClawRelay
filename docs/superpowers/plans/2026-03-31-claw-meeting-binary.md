# claw-meeting Binary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `claw-meeting` Swift binary that captures audio + screen during meetings, runs local transcription and visual analysis, and writes structured output to the buffer file for the daemon to ship.

**Architecture:** A Swift Package Manager command-line tool that uses FluidAudio for audio capture/transcription/diarisation and Apple Vision for face/body analysis. Runs as a child process of ClawRelay during meetings. Communicates via filesystem (JSONL buffer + session directory) and a Unix domain socket for control messages.

**Tech Stack:** Swift 5.10, FluidAudio (Parakeet TDT + diarisation), Apple Vision framework, CoreML (ArcFace), Core Audio HAL (system audio tap)

**Spec:** `docs/superpowers/specs/2026-03-31-meeting-intelligence-design.md`

**Scope:** This is Plan 1 of 3. Plans 2 (ClawRelay UI integration) and 3 (server-side processing) follow.

---

## File Structure

### New Files
```
mac-helper/claw-meeting/
  Package.swift                    # SPM manifest: FluidAudio dependency, macOS 14+ target
  Sources/ClawMeeting/
    ClawMeeting.swift              # Entry point (@main): arg parsing, mode dispatch (--run, --status, --stop)
    Config.swift                   # Paths, intervals, constants
    AudioCapture/
      SystemAudioCapture.swift     # Core Audio HAL process tap (adapted from OpenOats)
      MicCapture.swift             # AVAudioEngine input tap (adapted from OpenOats)
      AudioMixer.swift             # Combines system + mic streams, resamples to 16kHz mono
    Transcription/
      LiveTranscriber.swift        # FluidAudio streaming Parakeet + VAD wrapper
      BatchTranscriber.swift       # Post-meeting high-quality batch transcription
      DiarisationRunner.swift      # FluidAudio LS-EEND (streaming) + Pyannote (batch)
    Visual/
      ScreenCapture.swift          # CGWindowListCreateImage periodic + event-triggered
      FaceAnalyzer.swift           # Vision framework: face detection, landmarks, body pose
      FaceTracker.swift            # ArcFace CoreML embeddings for cross-frame re-ID
    Session/
      MeetingSession.swift         # Session state: id, start time, participants, paths
      MeetingRecorder.swift        # Top-level orchestrator: starts/stops all capture
      PauseSensitiveChecker.swift  # Reads pause-until / sensitive-mode files
    Output/
      BufferWriter.swift           # Appends transcript + visual events to meeting-buffer.jsonl
      SessionStore.swift           # Manages meeting-session/<id>/ directory (audio, frames)
    Control/
      SocketServer.swift           # Unix domain socket for stop/pause/status commands
  Tests/ClawMeetingTests/
    ConfigTests.swift              # Path resolution tests
    AudioMixerTests.swift          # Resampling + mixing logic tests
    BufferWriterTests.swift        # JSONL output format tests
    SessionStoreTests.swift        # Directory creation + cleanup tests
    PauseSensitiveCheckerTests.swift # Pause/sensitive mode behaviour tests
    ScreenCaptureTests.swift       # Capture interval + trigger logic tests
    FaceAnalyzerTests.swift        # Vision framework integration tests
    SocketServerTests.swift        # Control socket protocol tests
```

---

## Task 1: Swift Package Scaffold + Config

**Files:**
- Create: `mac-helper/claw-meeting/Package.swift`
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/main.swift`
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Config.swift`
- Create: `mac-helper/claw-meeting/Tests/ClawMeetingTests/ConfigTests.swift`

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClawMeeting",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.4"),
    ],
    targets: [
        .executableTarget(
            name: "ClawMeeting",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/ClawMeeting"
        ),
        .testTarget(
            name: "ClawMeetingTests",
            dependencies: ["ClawMeeting"],
            path: "Tests/ClawMeetingTests"
        ),
    ]
)
```

- [ ] **Step 2: Create Config.swift with path constants**

```swift
import Foundation

enum Config {
    static let bridgeDir = "\(NSHomeDirectory())/.context-bridge"
    static let meetingBufferPath = "\(bridgeDir)/meeting-buffer.jsonl"
    static let sessionDir = "\(bridgeDir)/meeting-session"
    static let briefingDir = "\(bridgeDir)/meeting-briefing"
    static let pidPath = "\(bridgeDir)/meeting-worker.pid"
    static let socketPath = "\(bridgeDir)/meeting-worker.sock"
    static let pauseUntilPath = "\(bridgeDir)/pause-until"
    static let sensitiveModePath = "\(bridgeDir)/sensitive-mode"
    static let modelCacheDir = "\(NSHomeDirectory())/Library/Application Support/ClawRelay/models"

    static let screenshotIntervalBaseline: TimeInterval = 30.0
    static let screenshotIntervalTriggered: TimeInterval = 5.0
    static let pauseCheckInterval: TimeInterval = 10.0
    static let sampleRate: Double = 16000.0
}
```

- [ ] **Step 3: Write failing test for Config paths**

```swift
import XCTest
@testable import ClawMeeting

final class ConfigTests: XCTestCase {
    func testBridgeDirIsUnderHome() {
        XCTAssertTrue(Config.bridgeDir.hasPrefix(NSHomeDirectory()))
    }

    func testMeetingBufferPathIsUnderBridgeDir() {
        XCTAssertTrue(Config.meetingBufferPath.hasPrefix(Config.bridgeDir))
        XCTAssertTrue(Config.meetingBufferPath.hasSuffix(".jsonl"))
    }

    func testSessionDirIsUnderBridgeDir() {
        XCTAssertTrue(Config.sessionDir.hasPrefix(Config.bridgeDir))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd mac-helper/claw-meeting && swift test --filter ConfigTests
```
Expected: PASS

- [ ] **Step 5: Create ClawMeeting.swift with arg parsing skeleton**

Note: Do NOT name this file `main.swift` — the `@main` attribute conflicts with Swift's special `main.swift` top-level code rules. Use `ClawMeeting.swift` instead.

```swift
import Foundation

@main
struct ClawMeeting {
    static func main() async throws {
        let args = CommandLine.arguments
        let mode = args.count > 1 ? args[1] : "--help"

        switch mode {
        case "--run":
            let meetingId = args.count > 2 ? args[2] : generateMeetingId()
            try await run(meetingId: meetingId)
        case "--status":
            printStatus()
        case "--stop":
            sendStop()
        default:
            print("Usage: claw-meeting --run [meeting-id] | --status | --stop")
        }
    }

    static func run(meetingId: String) async throws {
        print("Starting meeting capture: \(meetingId)")
        // TODO: wire up MeetingRecorder
        try await Task.sleep(for: .seconds(.max))
    }

    static func printStatus() {
        print("{\"state\": \"idle\"}")
    }

    static func sendStop() {
        print("Sending stop signal...")
    }

    static func generateMeetingId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
```

- [ ] **Step 6: Build to verify compilation**

```bash
cd mac-helper/claw-meeting && swift build
```
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add mac-helper/claw-meeting/
git commit -m "feat(claw-meeting): scaffold Swift package with config and entry point"
```

---

## Task 2: Buffer Writer (Output Layer)

**Files:**
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Output/BufferWriter.swift`
- Create: `mac-helper/claw-meeting/Tests/ClawMeetingTests/BufferWriterTests.swift`

Build the output layer first — everything upstream writes to it.

- [ ] **Step 1: Write failing tests for BufferWriter**

```swift
import XCTest
@testable import ClawMeeting

final class BufferWriterTests: XCTestCase {
    var tempDir: URL!
    var bufferPath: String!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        bufferPath = tempDir.appendingPathComponent("meeting-buffer.jsonl").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWriteTranscriptSegment() throws {
        let writer = BufferWriter(path: bufferPath)
        let segment = TranscriptSegment(
            meetingId: "test-meeting",
            timestamp: 124.5,
            speaker: "speaker_1",
            text: "Hello world",
            confidence: 0.91,
            words: [
                WordTiming(word: "Hello", start: 124.5, end: 124.8),
                WordTiming(word: "world", start: 124.85, end: 125.1),
            ],
            isFinal: true
        )
        try writer.writeTranscript(segment)

        let contents = try String(contentsOfFile: bufferPath, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)

        let decoded = try JSONDecoder().decode(BufferEntry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded.type, "transcript")
        XCTAssertEqual(decoded.meetingId, "test-meeting")
    }

    func testWriteVisualEvent() throws {
        let writer = BufferWriter(path: bufferPath)
        let event = VisualEvent(
            meetingId: "test-meeting",
            timestamp: 124.5,
            alignedTranscriptSegment: 31,
            trigger: "keyword_price",
            participants: [
                ParticipantObservation(
                    faceId: "face_001",
                    gridPosition: "top-right",
                    mouthOpen: true,
                    gaze: "at_camera",
                    headTilt: -3.2,
                    bodyLean: "forward"
                )
            ]
        )
        try writer.writeVisual(event)

        let contents = try String(contentsOfFile: bufferPath, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"type\":\"visual\""))
    }

    func testMultipleWritesAppend() throws {
        let writer = BufferWriter(path: bufferPath)
        let segment = TranscriptSegment(
            meetingId: "m", timestamp: 0, speaker: "s",
            text: "a", confidence: 1.0, words: [], isFinal: true
        )
        try writer.writeTranscript(segment)
        try writer.writeTranscript(segment)

        let contents = try String(contentsOfFile: bufferPath, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd mac-helper/claw-meeting && swift test --filter BufferWriterTests
```
Expected: FAIL — types not defined

- [ ] **Step 3: Implement data models and BufferWriter**

```swift
// Sources/ClawMeeting/Output/BufferWriter.swift
import Foundation

struct WordTiming: Codable {
    let word: String
    let start: Double
    let end: Double
}

struct TranscriptSegment: Codable {
    let meetingId: String
    let timestamp: Double
    let speaker: String
    let text: String
    let confidence: Double
    let words: [WordTiming]
    let isFinal: Bool

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case timestamp, speaker, text, confidence, words
        case isFinal = "is_final"
    }
}

struct LandmarksSummary: Codable {
    let browRaised: Bool
    let browFurrowed: Bool
    let mouthOpenness: Double

    enum CodingKeys: String, CodingKey {
        case browRaised = "brow_raised"
        case browFurrowed = "brow_furrowed"
        case mouthOpenness = "mouth_openness"
    }
}

struct ParticipantObservation: Codable {
    let faceId: String
    let gridPosition: String
    let mouthOpen: Bool
    let gaze: String
    let headTilt: Double
    let bodyLean: String
    var landmarksSummary: LandmarksSummary?

    enum CodingKeys: String, CodingKey {
        case faceId = "face_id"
        case gridPosition = "grid_position"
        case mouthOpen = "mouth_open"
        case gaze
        case headTilt = "head_tilt"
        case bodyLean = "body_lean"
        case landmarksSummary = "landmarks_summary"
    }
}

/// Envelope for typed JSONL entries. Flattens type + payload into one JSON object.
struct TypedEnvelope<T: Encodable>: Encodable {
    let type: String
    let payload: T

    func encode(to encoder: Encoder) throws {
        // Encode payload first, then merge type into the same container
        try payload.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
    }

    enum CodingKeys: String, CodingKey {
        case type
    }
}

struct VisualEvent: Codable {
    let meetingId: String
    let timestamp: Double
    let alignedTranscriptSegment: Int?
    let trigger: String
    let participants: [ParticipantObservation]

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case timestamp
        case alignedTranscriptSegment = "aligned_transcript_segment"
        case trigger, participants
    }
}

struct BufferEntry: Codable {
    let type: String
    let meetingId: String

    enum CodingKeys: String, CodingKey {
        case type
        case meetingId = "meeting_id"
    }
}

final class BufferWriter {
    private let path: String
    private let encoder: JSONEncoder
    private let lock = NSLock()

    init(path: String = Config.meetingBufferPath) {
        self.path = path
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    func writeTranscript(_ segment: TranscriptSegment) throws {
        let envelope = TypedEnvelope(type: "transcript", payload: segment)
        try writeEntry(envelope)
    }

    func writeVisual(_ event: VisualEvent) throws {
        let envelope = TypedEnvelope(type: "visual", payload: event)
        try writeEntry(envelope)
    }

    private func writeEntry<T: Encodable>(_ value: T) throws {
        let data = try encoder.encode(value)
        let line = String(data: data, encoding: .utf8)! + "\n"

        lock.lock()
        defer { lock.unlock() }

        let fileHandle: FileHandle
        if FileManager.default.fileExists(atPath: path) {
            fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            fileHandle.seekToEndOfFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        }
        fileHandle.write(line.data(using: .utf8)!)
        fileHandle.closeFile()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd mac-helper/claw-meeting && swift test --filter BufferWriterTests
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mac-helper/claw-meeting/Sources/ClawMeeting/Output/BufferWriter.swift \
        mac-helper/claw-meeting/Tests/ClawMeetingTests/BufferWriterTests.swift
git commit -m "feat(claw-meeting): add BufferWriter with JSONL output for transcript + visual events"
```

---

## Task 3: Session Store (File Management)

**Files:**
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Output/SessionStore.swift`
- Create: `mac-helper/claw-meeting/Tests/ClawMeetingTests/SessionStoreTests.swift`

Manages the `~/.context-bridge/meeting-session/<id>/` directory for raw audio and screenshots.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClawMeeting

final class SessionStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCreateSessionDirectory() throws {
        let store = SessionStore(baseDir: tempDir.path)
        let session = try store.createSession(id: "test-meeting-001")

        // Session root directory should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.rootDir))
        // audioPath's parent directory should exist (audio.wav created later by WAVFileWriter)
        let audioDir = URL(fileURLWithPath: session.audioPath).deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioDir.path))
    }

    func testFramesDirectoryExists() throws {
        let store = SessionStore(baseDir: tempDir.path)
        let session = try store.createSession(id: "test-meeting-001")

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.framesDir))
    }

    func testCleanupRemovesOldSessions() throws {
        let store = SessionStore(baseDir: tempDir.path, maxAgeDays: 0)
        let _ = try store.createSession(id: "old-meeting")

        // Session exists
        let sessionPath = tempDir.appendingPathComponent("old-meeting").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        // Cleanup with maxAge 0 should remove it
        try store.cleanupOldSessions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd mac-helper/claw-meeting && swift test --filter SessionStoreTests
```

- [ ] **Step 3: Implement SessionStore**

```swift
import Foundation

struct SessionPaths {
    let id: String
    let rootDir: String
    let audioPath: String
    let framesDir: String
}

final class SessionStore {
    let baseDir: String
    let maxAgeDays: Int

    init(baseDir: String = Config.sessionDir, maxAgeDays: Int = 30) {
        self.baseDir = baseDir
        self.maxAgeDays = maxAgeDays
    }

    func createSession(id: String) throws -> SessionPaths {
        let sessionDir = "\(baseDir)/\(id)"
        let framesDir = "\(sessionDir)/frames"
        let audioPath = "\(sessionDir)/audio.wav"

        try FileManager.default.createDirectory(
            atPath: framesDir,
            withIntermediateDirectories: true
        )

        return SessionPaths(
            id: id,
            rootDir: sessionDir,
            audioPath: audioPath,
            framesDir: framesDir
        )
    }

    func cleanupOldSessions() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDir) else { return }

        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays * 86400))
        let contents = try fm.contentsOfDirectory(atPath: baseDir)

        for name in contents {
            let path = "\(baseDir)/\(name)"
            let attrs = try fm.attributesOfItem(atPath: path)
            if let created = attrs[.creationDate] as? Date, created < cutoff {
                try fm.removeItem(atPath: path)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd mac-helper/claw-meeting && swift test --filter SessionStoreTests
```

- [ ] **Step 5: Commit**

```bash
git add mac-helper/claw-meeting/Sources/ClawMeeting/Output/SessionStore.swift \
        mac-helper/claw-meeting/Tests/ClawMeetingTests/SessionStoreTests.swift
git commit -m "feat(claw-meeting): add SessionStore for meeting session directory management"
```

---

## Task 4: Pause/Sensitive Mode Checker

**Files:**
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Session/PauseSensitiveChecker.swift`
- Create: `mac-helper/claw-meeting/Tests/ClawMeetingTests/PauseSensitiveCheckerTests.swift`

Reads `~/.context-bridge/pause-until` and `sensitive-mode` files every 10 seconds.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClawMeeting

final class PauseSensitiveCheckerTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testNotPausedWhenFileDoesNotExist() {
        let checker = PauseSensitiveChecker(
            pausePath: tempDir.appendingPathComponent("pause-until").path,
            sensitivePath: tempDir.appendingPathComponent("sensitive-mode").path
        )
        XCTAssertFalse(checker.isPaused)
    }

    func testPausedWhenFutureTimestamp() throws {
        let pausePath = tempDir.appendingPathComponent("pause-until").path
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        try future.write(toFile: pausePath, atomically: true, encoding: .utf8)

        let checker = PauseSensitiveChecker(
            pausePath: pausePath,
            sensitivePath: tempDir.appendingPathComponent("sensitive-mode").path
        )
        XCTAssertTrue(checker.isPaused)
    }

    func testNotPausedWhenPastTimestamp() throws {
        let pausePath = tempDir.appendingPathComponent("pause-until").path
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        try past.write(toFile: pausePath, atomically: true, encoding: .utf8)

        let checker = PauseSensitiveChecker(
            pausePath: pausePath,
            sensitivePath: tempDir.appendingPathComponent("sensitive-mode").path
        )
        XCTAssertFalse(checker.isPaused)
    }

    func testSensitiveModeWhenFileExists() throws {
        let sensitivePath = tempDir.appendingPathComponent("sensitive-mode").path
        try "on".write(toFile: sensitivePath, atomically: true, encoding: .utf8)

        let checker = PauseSensitiveChecker(
            pausePath: tempDir.appendingPathComponent("pause-until").path,
            sensitivePath: sensitivePath
        )
        XCTAssertTrue(checker.isSensitive)
    }

    func testNotSensitiveWhenFileDoesNotExist() {
        let checker = PauseSensitiveChecker(
            pausePath: tempDir.appendingPathComponent("pause-until").path,
            sensitivePath: tempDir.appendingPathComponent("sensitive-mode").path
        )
        XCTAssertFalse(checker.isSensitive)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd mac-helper/claw-meeting && swift test --filter PauseSensitiveCheckerTests
```

- [ ] **Step 3: Implement PauseSensitiveChecker**

```swift
import Foundation

final class PauseSensitiveChecker {
    private let pausePath: String
    private let sensitivePath: String
    private let formatter = ISO8601DateFormatter()

    init(
        pausePath: String = Config.pauseUntilPath,
        sensitivePath: String = Config.sensitiveModePath
    ) {
        self.pausePath = pausePath
        self.sensitivePath = sensitivePath
    }

    var isPaused: Bool {
        guard let content = try? String(contentsOfFile: pausePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        guard let pauseUntil = formatter.date(from: content) else {
            // Also handle Unix timestamp format
            if let ts = Double(content) {
                return Date(timeIntervalSince1970: ts) > Date()
            }
            return false
        }
        return pauseUntil > Date()
    }

    var isSensitive: Bool {
        FileManager.default.fileExists(atPath: sensitivePath)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd mac-helper/claw-meeting && swift test --filter PauseSensitiveCheckerTests
```

- [ ] **Step 5: Commit**

```bash
git add mac-helper/claw-meeting/Sources/ClawMeeting/Session/PauseSensitiveChecker.swift \
        mac-helper/claw-meeting/Tests/ClawMeetingTests/PauseSensitiveCheckerTests.swift
git commit -m "feat(claw-meeting): add PauseSensitiveChecker for pause/sensitive mode"
```

---

## Task 5: Control Socket Server

**Files:**
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Control/SocketServer.swift`
- Create: `mac-helper/claw-meeting/Tests/ClawMeetingTests/SocketServerTests.swift`

Unix domain socket for ClawRelay to send stop/pause/status commands.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClawMeeting

final class SocketServerTests: XCTestCase {
    var tempDir: URL!
    var socketPath: String!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        socketPath = tempDir.appendingPathComponent("test.sock").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testParseStopCommand() {
        let cmd = SocketCommand.parse("STOP\n")
        XCTAssertEqual(cmd, .stop)
    }

    func testParseStatusCommand() {
        let cmd = SocketCommand.parse("STATUS\n")
        XCTAssertEqual(cmd, .status)
    }

    func testParsePauseCommand() {
        let cmd = SocketCommand.parse("PAUSE\n")
        XCTAssertEqual(cmd, .pause)
    }

    func testParseResumeCommand() {
        let cmd = SocketCommand.parse("RESUME\n")
        XCTAssertEqual(cmd, .resume)
    }

    func testParseUnknownCommand() {
        let cmd = SocketCommand.parse("FOOBAR\n")
        XCTAssertEqual(cmd, .unknown)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd mac-helper/claw-meeting && swift test --filter SocketServerTests
```

- [ ] **Step 3: Implement SocketCommand and SocketServer**

```swift
import Foundation

enum SocketCommand: Equatable {
    case stop
    case status
    case pause
    case resume
    case unknown

    static func parse(_ input: String) -> SocketCommand {
        switch input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "STOP": return .stop
        case "STATUS": return .status
        case "PAUSE": return .pause
        case "RESUME": return .resume
        default: return .unknown
        }
    }
}

final class SocketServer {
    private let path: String
    private var fileDescriptor: Int32 = -1
    private var running = false
    var onCommand: ((SocketCommand) -> String)?

    init(path: String = Config.socketPath) {
        self.path = path
    }

    func start() throws {
        // Remove stale socket
        unlink(path)

        fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw NSError(domain: "SocketServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(Int(MemoryLayout.size(ofValue: addr.sun_path)), path.count + 1))
            }
        }

        // Verify path fits in sockaddr_un.sun_path (104 bytes on macOS)
        guard path.utf8.count < 104 else {
            throw NSError(domain: "SocketServer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Socket path too long (\(path.utf8.count) bytes, max 103)"])
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fileDescriptor, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fileDescriptor)
            throw NSError(domain: "SocketServer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to bind: \(String(cString: strerror(errno)))"])
        }

        listen(fileDescriptor, 5)
        running = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        running = false
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        unlink(path)
    }

    private func acceptLoop() {
        while running {
            let clientFd = accept(fileDescriptor, nil, nil)
            guard clientFd >= 0 else { continue }

            var buffer = [UInt8](repeating: 0, count: 256)
            let bytesRead = read(clientFd, &buffer, buffer.count)
            if bytesRead > 0 {
                let input = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                let command = SocketCommand.parse(input)
                let response = onCommand?(command) ?? "{\"error\": \"no handler\"}"
                write(clientFd, response, response.utf8.count)
            }
            close(clientFd)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd mac-helper/claw-meeting && swift test --filter SocketServerTests
```

- [ ] **Step 5: Commit**

```bash
git add mac-helper/claw-meeting/Sources/ClawMeeting/Control/SocketServer.swift \
        mac-helper/claw-meeting/Tests/ClawMeetingTests/SocketServerTests.swift
git commit -m "feat(claw-meeting): add Unix domain socket server for control commands"
```

---

## Task 6: Audio Capture (System + Mic)

**Files:**
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/AudioCapture/SystemAudioCapture.swift`
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/AudioCapture/MicCapture.swift`
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/AudioCapture/AudioMixer.swift`
- Create: `mac-helper/claw-meeting/Tests/ClawMeetingTests/AudioMixerTests.swift`

Adapted from OpenOats. System audio uses Core Audio HAL process tap; mic uses AVAudioEngine.

**Important:** SystemAudioCapture and MicCapture require hardware access and cannot be fully unit tested. Adapt from OpenOats' tested implementations. AudioMixer (the resampling/mixing logic) CAN be tested.

- [ ] **Step 1: Create SystemAudioCapture (adapted from OpenOats)**

```swift
import AVFoundation
import CoreAudio

/// Captures system audio (what you hear) via Core Audio HAL process tap.
/// Requires Screen Recording permission on macOS.
/// Adapted from OpenOats (MIT licensed).
final class SystemAudioCapture {
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() throws {
        // 1. Create process tap (captures all system audio)
        var tapDesc = CATapDescription(stereoMixdownOfProcesses: [])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted

        var tapSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let tapStatus = AudioHardwareCreateProcessTap(&tapDesc, &tapID)
        guard tapStatus == noErr else {
            throw AudioCaptureError.tapCreationFailed(tapStatus)
        }

        // 2. Create aggregate device with the tap as sub-device
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "ClawMeeting System Tap",
            kAudioAggregateDeviceUIDKey as String: "com.openclaw.clawmeeting.systap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString]
            ],
        ]

        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateDeviceID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw AudioCaptureError.aggregateDeviceFailed(aggStatus)
        }

        // 3. Install IO proc to stream audio buffers
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) {
            [weak self] _, _, inputData, _, _ in
            guard let self, let inputData else { return }
            // Convert AudioBufferList to AVAudioPCMBuffer and call handler
            let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let firstBuffer = bufferList.first,
                  let data = firstBuffer.mData else { return }

            let frameCount = firstBuffer.mDataByteSize / 4 // Float32
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
            memcpy(pcmBuffer.floatChannelData![0], data, Int(firstBuffer.mDataByteSize))

            self.onBuffer?(pcmBuffer)
        }

        AudioDeviceStart(aggregateDeviceID, ioProcID)
        running = true
    }

    func stop() {
        guard running else { return }
        running = false

        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    deinit { stop() }
}

enum AudioCaptureError: Error {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case engineStartFailed(Error)
}
```

- [ ] **Step 2: Create MicCapture (adapted from OpenOats)**

```swift
import AVFoundation

/// Captures microphone input via AVAudioEngine.
/// Requires Microphone permission on macOS.
final class MicCapture {
    private let engine = AVAudioEngine()
    private var running = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit { stop() }
}
```

- [ ] **Step 3: Create AudioMixer with resampling**

```swift
import AVFoundation
import Accelerate

/// Mixes system audio + mic streams and resamples to 16kHz mono for transcription.
final class AudioMixer {
    private let targetSampleRate: Double
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    let outputFormat: AVAudioFormat

    var onMixedBuffer: (([Float]) -> Void)?

    init(targetSampleRate: Double = Config.sampleRate) {
        self.targetSampleRate = targetSampleRate
        self.outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: targetSampleRate, channels: 1
        )!
    }

    func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let resampled = resample(buffer, using: &micConverter) else { return }
        onMixedBuffer?(Array(UnsafeBufferPointer(
            start: resampled.floatChannelData![0],
            count: Int(resampled.frameLength)
        )))
    }

    func processSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let resampled = resample(buffer, using: &systemConverter) else { return }
        onMixedBuffer?(Array(UnsafeBufferPointer(
            start: resampled.floatChannelData![0],
            count: Int(resampled.frameLength)
        )))
    }

    private func resample(
        _ buffer: AVAudioPCMBuffer,
        using converter: inout AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: outputFrameCount
        ) else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        return error == nil ? outputBuffer : nil
    }

    /// Compute RMS level of a float buffer (for level metering)
    static func rmsLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }
}
```

- [ ] **Step 4: Write AudioMixer tests**

```swift
import XCTest
import AVFoundation
@testable import ClawMeeting

final class AudioMixerTests: XCTestCase {
    func testRmsLevelOfSilence() {
        let silence = [Float](repeating: 0.0, count: 1000)
        let rms = AudioMixer.rmsLevel(silence)
        XCTAssertEqual(rms, 0.0, accuracy: 0.001)
    }

    func testRmsLevelOfSignal() {
        let signal = [Float](repeating: 0.5, count: 1000)
        let rms = AudioMixer.rmsLevel(signal)
        XCTAssertEqual(rms, 0.5, accuracy: 0.01)
    }

    func testRmsLevelOfEmptyBuffer() {
        let rms = AudioMixer.rmsLevel([])
        XCTAssertEqual(rms, 0.0)
    }

    func testOutputFormatIs16kHzMono() {
        let mixer = AudioMixer()
        XCTAssertEqual(mixer.outputFormat.sampleRate, 16000.0)
        XCTAssertEqual(mixer.outputFormat.channelCount, 1)
    }
}
```

- [ ] **Step 5: Run tests**

```bash
cd mac-helper/claw-meeting && swift test --filter AudioMixerTests
```
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add mac-helper/claw-meeting/Sources/ClawMeeting/AudioCapture/
git add mac-helper/claw-meeting/Tests/ClawMeetingTests/AudioMixerTests.swift
git commit -m "feat(claw-meeting): add audio capture (system tap + mic) and mixer with 16kHz resampling"
```

---

## Task 7: FluidAudio Transcription Wrapper

**Files:**
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Transcription/LiveTranscriber.swift`
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Transcription/BatchTranscriber.swift`
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Transcription/DiarisationRunner.swift`

Wraps FluidAudio APIs for streaming and batch transcription + diarisation.

**Note:** These require FluidAudio models to be downloaded. Tests are integration-level and should be marked as requiring hardware. Focus on the API wrapper correctness, not transcription quality.

- [ ] **Step 0: Verify FluidAudio's actual public API surface**

Before writing wrappers, verify what's actually available:

```bash
cd mac-helper/claw-meeting && swift package resolve
# Then inspect the public API:
grep -r "public" .build/checkouts/FluidAudio/Sources/ | head -50
# Or read the README:
cat .build/checkouts/FluidAudio/README.md | head -100
```

The code below uses speculative API names (`FluidTranscriber`, `FluidDiarizer`, `.parakeetTDTv3`). **Adjust all wrapper code to match the actual FluidAudio API.** The pattern stays the same — the method names and types will likely differ.

- [ ] **Step 1: Create LiveTranscriber**

```swift
import FluidAudio
import Foundation

/// Wraps FluidAudio's streaming Parakeet TDT for live transcription during meetings.
final class LiveTranscriber {
    private var transcriber: FluidTranscriber?
    private let modelCacheDir: String
    private var segmentIndex = 0

    var onSegment: ((TranscriptSegment) -> Void)?
    var meetingId: String = ""

    init(modelCacheDir: String = Config.modelCacheDir) {
        self.modelCacheDir = modelCacheDir
    }

    func start() async throws {
        transcriber = try FluidTranscriber(
            model: .parakeetTDTv3,
            cacheDirectory: URL(fileURLWithPath: modelCacheDir)
        )
    }

    func processAudio(_ samples: [Float], sampleRate: Double = Config.sampleRate) async throws {
        guard let transcriber else { return }

        let result = try await transcriber.transcribe(
            samples: samples,
            sampleRate: Int(sampleRate)
        )

        guard !result.text.isEmpty else { return }

        let segment = TranscriptSegment(
            meetingId: meetingId,
            timestamp: result.startTime ?? 0,
            speaker: "unknown", // diarisation assigns this later
            text: result.text,
            confidence: result.confidence ?? 0.9,
            words: result.words?.map { WordTiming(word: $0.word, start: $0.start, end: $0.end) } ?? [],
            isFinal: true
        )
        segmentIndex += 1
        onSegment?(segment)
    }

    func stop() {
        transcriber = nil
    }
}
```

- [ ] **Step 2: Create BatchTranscriber**

```swift
import FluidAudio
import Foundation

/// Runs high-quality post-meeting batch transcription on the full audio recording.
final class BatchTranscriber {
    private let modelCacheDir: String

    init(modelCacheDir: String = Config.modelCacheDir) {
        self.modelCacheDir = modelCacheDir
    }

    func transcribe(audioURL: URL) async throws -> [TranscriptSegment] {
        let transcriber = try FluidTranscriber(
            model: .parakeetTDTv3,
            cacheDirectory: URL(fileURLWithPath: modelCacheDir)
        )

        let result = try await transcriber.transcribe(audioURL: audioURL)

        return result.segments.enumerated().map { index, seg in
            TranscriptSegment(
                meetingId: "", // caller sets this
                timestamp: seg.start,
                speaker: "unknown", // diarisation assigns later
                text: seg.text,
                confidence: seg.confidence ?? 0.9,
                words: seg.words?.map { WordTiming(word: $0.word, start: $0.start, end: $0.end) } ?? [],
                isFinal: true
            )
        }
    }
}
```

- [ ] **Step 3: Create DiarisationRunner**

```swift
import FluidAudio
import Foundation

/// Runs speaker diarisation: LS-EEND for streaming, Pyannote for batch.
final class DiarisationRunner {
    private let modelCacheDir: String

    init(modelCacheDir: String = Config.modelCacheDir) {
        self.modelCacheDir = modelCacheDir
    }

    /// Batch diarisation on a complete audio file. Returns speaker labels per time segment.
    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        let diarizer = try FluidDiarizer(
            cacheDirectory: URL(fileURLWithPath: modelCacheDir)
        )

        let result = try await diarizer.diarize(audioURL: audioURL)

        return result.segments.map { seg in
            SpeakerSegment(
                speaker: seg.speaker,
                start: seg.start,
                end: seg.end
            )
        }
    }

    /// Merge diarisation labels into transcript segments.
    static func assignSpeakers(
        transcript: [TranscriptSegment],
        speakers: [SpeakerSegment]
    ) -> [TranscriptSegment] {
        transcript.map { segment in
            let matchingSpeaker = speakers.first { sp in
                segment.timestamp >= sp.start && segment.timestamp < sp.end
            }
            var updated = segment
            // TranscriptSegment is a struct, so we need to recreate it
            return TranscriptSegment(
                meetingId: segment.meetingId,
                timestamp: segment.timestamp,
                speaker: matchingSpeaker?.speaker ?? segment.speaker,
                text: segment.text,
                confidence: segment.confidence,
                words: segment.words,
                isFinal: segment.isFinal
            )
        }
    }
}

struct SpeakerSegment {
    let speaker: String
    let start: Double
    let end: Double
}
```

- [ ] **Step 4: Build to verify compilation with FluidAudio**

```bash
cd mac-helper/claw-meeting && swift build
```
Expected: BUILD SUCCEEDED

Note: If FluidAudio APIs differ from what's shown here (method names, parameter types), adjust the wrapper to match the actual FluidAudio public API. The wrapper pattern stays the same — the implementation details may need tweaking based on FluidAudio's actual Swift API surface.

- [ ] **Step 5: Commit**

```bash
git add mac-helper/claw-meeting/Sources/ClawMeeting/Transcription/
git commit -m "feat(claw-meeting): add FluidAudio transcription wrappers (live + batch + diarisation)"
```

---

## Task 8: Screen Capture + Vision Analysis

**Files:**
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Visual/ScreenCapture.swift`
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Visual/FaceAnalyzer.swift`
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Visual/FaceTracker.swift`
- Create: `mac-helper/claw-meeting/Tests/ClawMeetingTests/ScreenCaptureTests.swift`
- Create: `mac-helper/claw-meeting/Tests/ClawMeetingTests/FaceAnalyzerTests.swift`

- [ ] **Step 1: Create ScreenCapture**

```swift
import AppKit
import Foundation

/// Captures screen screenshots at configurable intervals.
/// Increases frequency when triggered by transcript keywords.
final class ScreenCapture {
    private var timer: DispatchSourceTimer?
    private var currentInterval: TimeInterval
    private let framesDir: String
    private var frameCount = 0
    private var triggeredUntil: Date?

    var onCapture: ((URL, Int) -> Void)?

    init(framesDir: String, baselineInterval: TimeInterval = Config.screenshotIntervalBaseline) {
        self.framesDir = framesDir
        self.currentInterval = baselineInterval
    }

    func start() {
        scheduleNextCapture()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Trigger increased capture frequency for the next 30 seconds.
    func triggerHighFrequency(reason: String) {
        triggeredUntil = Date().addingTimeInterval(30)
    }

    private func scheduleNextCapture() {
        let interval: TimeInterval
        if let until = triggeredUntil, until > Date() {
            interval = Config.screenshotIntervalTriggered
        } else {
            triggeredUntil = nil
            interval = Config.screenshotIntervalBaseline
        }

        // Cancel previous timer to avoid leaking DispatchSource timers
        timer?.cancel()

        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer?.schedule(deadline: .now() + interval)
        timer?.setEventHandler { [weak self] in
            self?.captureFrame()
            self?.scheduleNextCapture()
        }
        timer?.resume()
    }

    private func captureFrame() {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming]
        ) else { return }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return }

        frameCount += 1
        let filename = String(format: "frame_%05d.png", frameCount)
        let path = "\(framesDir)/\(filename)"

        try? pngData.write(to: URL(fileURLWithPath: path))
        onCapture?(URL(fileURLWithPath: path), frameCount)
    }
}
```

- [ ] **Step 2: Create FaceAnalyzer**

```swift
import Vision
import AppKit
import Foundation

/// Runs Apple Vision framework on screenshots to detect faces, landmarks, and body pose.
final class FaceAnalyzer {

    struct FaceObservation {
        let boundingBox: CGRect
        let landmarks: VNFaceLandmarks2D?
        let mouthOpen: Bool
        let browFurrowed: Bool
        let gazeDirection: String // "at_camera", "left", "right", "down"
    }

    struct BodyObservation {
        let headTilt: Double // degrees
        let bodyLean: String // "forward", "back", "neutral"
    }

    /// Analyze a screenshot for faces and body poses.
    func analyze(imageURL: URL) throws -> [ParticipantObservation] {
        guard let cgImage = loadCGImage(from: imageURL) else { return [] }

        let faceRequest = VNDetectFaceLandmarksRequest()
        let bodyRequest = VNDetectHumanBodyPose3DRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([faceRequest, bodyRequest])

        let faces = faceRequest.results ?? []
        let bodies = bodyRequest.results ?? []

        return faces.enumerated().map { index, face in
            let landmarks = face.landmarks
            let mouthOpen = isMouthOpen(landmarks: landmarks)
            let browFurrowed = isBrowFurrowed(landmarks: landmarks)
            let gaze = estimateGaze(landmarks: landmarks)
            let headTilt = estimateHeadTilt(face: face)
            let bodyLean = estimateBodyLean(bodies: bodies, faceIndex: index)
            let gridPosition = estimateGridPosition(
                boundingBox: face.boundingBox,
                imageSize: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            )

            return ParticipantObservation(
                faceId: "face_\(String(format: "%03d", index))",
                gridPosition: gridPosition,
                mouthOpen: mouthOpen,
                gaze: gaze,
                headTilt: headTilt,
                bodyLean: bodyLean
            )
        }
    }

    // MARK: - Helpers

    private func loadCGImage(from url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }

    private func isMouthOpen(landmarks: VNFaceLandmarks2D?) -> Bool {
        guard let outerLips = landmarks?.outerLips,
              let innerLips = landmarks?.innerLips else { return false }
        // Compare vertical distance of inner lips to outer lips width
        let outerPoints = outerLips.normalizedPoints
        let innerPoints = innerLips.normalizedPoints
        guard outerPoints.count >= 6, innerPoints.count >= 4 else { return false }
        let mouthWidth = abs(outerPoints[0].x - outerPoints[outerPoints.count / 2].x)
        let mouthHeight = abs(innerPoints[1].y - innerPoints[innerPoints.count - 1].y)
        return mouthWidth > 0 && (mouthHeight / mouthWidth) > 0.15
    }

    private func isBrowFurrowed(landmarks: VNFaceLandmarks2D?) -> Bool {
        guard let leftBrow = landmarks?.leftEyebrow,
              let leftEye = landmarks?.leftEye else { return false }
        let browPoints = leftBrow.normalizedPoints
        let eyePoints = leftEye.normalizedPoints
        guard let browMid = browPoints.middle, let eyeTop = eyePoints.max(by: { $0.y < $1.y }) else { return false }
        // Furrowed = brow closer to eye than normal
        return abs(browMid.y - eyeTop.y) < 0.03
    }

    private func estimateGaze(landmarks: VNFaceLandmarks2D?) -> String {
        guard let leftPupil = landmarks?.leftPupil,
              let rightPupil = landmarks?.rightPupil,
              let nose = landmarks?.nose else { return "at_camera" }

        let leftP = leftPupil.normalizedPoints
        let rightP = rightPupil.normalizedPoints
        let noseP = nose.normalizedPoints

        guard let lp = leftP.first, let rp = rightP.first, let np = noseP.middle else {
            return "at_camera"
        }

        let pupilCenterX = (lp.x + rp.x) / 2
        let offset = pupilCenterX - np.x

        if abs(offset) < 0.02 { return "at_camera" }
        return offset > 0 ? "right" : "left"
    }

    private func estimateHeadTilt(face: VNFaceObservation) -> Double {
        return Double(face.roll?.doubleValue ?? 0) * 180.0 / .pi
    }

    private func estimateBodyLean(bodies: [VNHumanBodyPose3DObservation], faceIndex: Int) -> String {
        guard faceIndex < bodies.count else { return "neutral" }
        // Use shoulder-to-head Z-offset as lean indicator
        // Positive Z = leaning forward, Negative Z = leaning back
        guard let head = try? bodies[faceIndex].recognizedPoint(.centerHead),
              let spine = try? bodies[faceIndex].recognizedPoint(.centerShoulder) else {
            return "neutral"
        }
        let zDiff = head.position.z - spine.position.z
        if zDiff > 0.05 { return "forward" }
        if zDiff < -0.05 { return "back" }
        return "neutral"
    }

    private func estimateGridPosition(boundingBox: CGRect, imageSize: CGSize) -> String {
        let centerX = boundingBox.midX
        let centerY = 1.0 - boundingBox.midY // Vision uses bottom-left origin
        let col = centerX < 0.5 ? "left" : "right"
        let row = centerY < 0.5 ? "bottom" : "top"
        return "\(row)-\(col)"
    }
}

extension Array where Element == CGPoint {
    var middle: CGPoint? {
        guard !isEmpty else { return nil }
        return self[count / 2]
    }
}
```

- [ ] **Step 3: Create FaceTracker stub**

For ArcFace-based face re-identification. Full CoreML integration deferred to Plan 2 — for now, track faces by grid position (sufficient for video call grid layouts).

```swift
import Foundation

/// Tracks participant faces across frames using grid position.
/// Full ArcFace CoreML re-ID will be added when the model is integrated.
final class FaceTracker {
    private var knownFaces: [String: String] = [:] // gridPosition -> faceId

    /// Assign stable face IDs based on grid position.
    func trackFaces(_ observations: [ParticipantObservation]) -> [ParticipantObservation] {
        observations.map { obs in
            let stableId: String
            if let existing = knownFaces[obs.gridPosition] {
                stableId = existing
            } else {
                stableId = "face_\(String(format: "%03d", knownFaces.count + 1))"
                knownFaces[obs.gridPosition] = stableId
            }
            return ParticipantObservation(
                faceId: stableId,
                gridPosition: obs.gridPosition,
                mouthOpen: obs.mouthOpen,
                gaze: obs.gaze,
                headTilt: obs.headTilt,
                bodyLean: obs.bodyLean
            )
        }
    }

    func reset() {
        knownFaces.removeAll()
    }
}
```

- [ ] **Step 4: Write ScreenCapture interval logic tests**

```swift
import XCTest
@testable import ClawMeeting

final class ScreenCaptureTests: XCTestCase {
    func testBaselineIntervalIs30Seconds() {
        XCTAssertEqual(Config.screenshotIntervalBaseline, 30.0)
    }

    func testTriggeredIntervalIs5Seconds() {
        XCTAssertEqual(Config.screenshotIntervalTriggered, 5.0)
    }
}
```

- [ ] **Step 5: Write FaceAnalyzer grid position tests**

```swift
import XCTest
import CoreGraphics
@testable import ClawMeeting

final class FaceAnalyzerTests: XCTestCase {
    func testFaceTrackerAssignsStableIds() {
        let tracker = FaceTracker()
        let obs1 = [
            ParticipantObservation(faceId: "", gridPosition: "top-left", mouthOpen: false, gaze: "at_camera", headTilt: 0, bodyLean: "neutral"),
            ParticipantObservation(faceId: "", gridPosition: "top-right", mouthOpen: true, gaze: "left", headTilt: 2.0, bodyLean: "forward"),
        ]
        let tracked1 = tracker.trackFaces(obs1)
        XCTAssertEqual(tracked1[0].faceId, "face_001")
        XCTAssertEqual(tracked1[1].faceId, "face_002")

        // Same positions in next frame should get same IDs
        let obs2 = [
            ParticipantObservation(faceId: "", gridPosition: "top-left", mouthOpen: true, gaze: "at_camera", headTilt: 0, bodyLean: "neutral"),
            ParticipantObservation(faceId: "", gridPosition: "top-right", mouthOpen: false, gaze: "right", headTilt: -1.0, bodyLean: "back"),
        ]
        let tracked2 = tracker.trackFaces(obs2)
        XCTAssertEqual(tracked2[0].faceId, "face_001")
        XCTAssertEqual(tracked2[1].faceId, "face_002")
    }

    func testFaceTrackerReset() {
        let tracker = FaceTracker()
        let obs = [
            ParticipantObservation(faceId: "", gridPosition: "top-left", mouthOpen: false, gaze: "at_camera", headTilt: 0, bodyLean: "neutral"),
        ]
        let _ = tracker.trackFaces(obs)
        tracker.reset()
        let tracked = tracker.trackFaces(obs)
        // After reset, IDs start fresh
        XCTAssertEqual(tracked[0].faceId, "face_001")
    }
}
```

- [ ] **Step 6: Run tests**

```bash
cd mac-helper/claw-meeting && swift test --filter "ScreenCaptureTests|FaceAnalyzerTests"
```
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add mac-helper/claw-meeting/Sources/ClawMeeting/Visual/
git add mac-helper/claw-meeting/Tests/ClawMeetingTests/ScreenCaptureTests.swift
git add mac-helper/claw-meeting/Tests/ClawMeetingTests/FaceAnalyzerTests.swift
git commit -m "feat(claw-meeting): add screen capture, face analysis (Vision), and face tracker"
```

---

## Task 9: Meeting Session Model

**Files:**
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingSession.swift`

- [ ] **Step 1: Create MeetingSession**

```swift
import Foundation

/// Holds all state for a running meeting capture session.
final class MeetingSession {
    let id: String
    let startedAt: Date
    let paths: SessionPaths

    private(set) var segmentCount = 0
    private(set) var frameCount = 0
    private(set) var state: SessionState = .recording

    enum SessionState: String {
        case recording
        case paused
        case sensitive
        case finalizing
        case completed
    }

    init(id: String, paths: SessionPaths) {
        self.id = id
        self.startedAt = Date()
        self.paths = paths
    }

    var elapsedSeconds: Int {
        Int(Date().timeIntervalSince(startedAt))
    }

    func incrementSegments() { segmentCount += 1 }
    func incrementFrames() { frameCount += 1 }

    func statusJSON() -> String {
        """
        {"state":"\(state.rawValue)","meeting_id":"\(id)","elapsed_seconds":\(elapsedSeconds),\
        "transcript_segments":\(segmentCount),"screenshots_taken":\(frameCount)}
        """
    }

    func transition(to newState: SessionState) {
        state = newState
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd mac-helper/claw-meeting && swift build
```

- [ ] **Step 3: Commit**

```bash
git add mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingSession.swift
git commit -m "feat(claw-meeting): add MeetingSession model for session state tracking"
```

---

## Task 10: Meeting Recorder (Top-Level Orchestrator)

**Files:**
- Create: `mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift`
- Modify: `mac-helper/claw-meeting/Sources/ClawMeeting/ClawMeeting.swift`

The central orchestrator that wires together audio capture, transcription, screen capture, visual analysis, buffer writing, pause checking, and control socket.

- [ ] **Step 1: Create MeetingRecorder**

```swift
import Foundation

/// Orchestrates all meeting capture: audio, transcription, screen capture, visual analysis.
/// This is the main runtime that `main.swift --run` invokes.
final class MeetingRecorder {
    private let meetingId: String
    private let bufferWriter: BufferWriter
    private let sessionStore: SessionStore
    private let pauseChecker: PauseSensitiveChecker
    private let socketServer: SocketServer

    private var systemAudio: SystemAudioCapture?
    private var micCapture: MicCapture?
    private var audioMixer: AudioMixer?
    private var liveTranscriber: LiveTranscriber?
    private var screenCapture: ScreenCapture?
    private var faceAnalyzer: FaceAnalyzer?
    private var faceTracker: FaceTracker?
    private var session: MeetingSession?

    private var pauseCheckTimer: DispatchSourceTimer?
    private var shouldStop = false

    init(meetingId: String) {
        self.meetingId = meetingId
        self.bufferWriter = BufferWriter()
        self.sessionStore = SessionStore()
        self.pauseChecker = PauseSensitiveChecker()
        self.socketServer = SocketServer()
    }

    func run() async throws {
        // 1. Create session directory
        let paths = try sessionStore.createSession(id: meetingId)
        let session = MeetingSession(id: meetingId, paths: paths)
        self.session = session

        // 2. Write PID file
        try "\(ProcessInfo.processInfo.processIdentifier)"
            .write(toFile: Config.pidPath, atomically: true, encoding: .utf8)

        // 3. Start control socket
        socketServer.onCommand = { [weak self] cmd in
            self?.handleCommand(cmd) ?? "{\"error\": \"recorder gone\"}"
        }
        try socketServer.start()

        // 4. Start audio capture
        let mixer = AudioMixer()
        self.audioMixer = mixer

        let transcriber = LiveTranscriber()
        transcriber.meetingId = meetingId
        transcriber.onSegment = { [weak self] segment in
            guard let self, let session = self.session else { return }
            if session.state == .sensitive { return } // suppress in sensitive mode
            try? self.bufferWriter.writeTranscript(segment)
            session.incrementSegments()

            // Check for trigger keywords in transcript
            self.checkKeywordTriggers(segment.text)
        }
        self.liveTranscriber = transcriber
        try await transcriber.start()

        mixer.onMixedBuffer = { [weak transcriber] samples in
            Task {
                try? await transcriber?.processAudio(samples)
            }
        }

        let sysAudio = SystemAudioCapture()
        sysAudio.onBuffer = { [weak mixer] buffer in mixer?.processSystemBuffer(buffer) }
        try sysAudio.start()
        self.systemAudio = sysAudio

        let mic = MicCapture()
        mic.onBuffer = { [weak mixer] buffer in mixer?.processMicBuffer(buffer) }
        try mic.start()
        self.micCapture = mic

        // 5. Start screen capture + visual analysis
        let analyzer = FaceAnalyzer()
        let tracker = FaceTracker()
        self.faceAnalyzer = analyzer
        self.faceTracker = tracker

        let capture = ScreenCapture(framesDir: paths.framesDir)
        capture.onCapture = { [weak self] frameURL, frameIndex in
            guard let self, let session = self.session else { return }
            if session.state == .sensitive || session.state == .paused { return }

            session.incrementFrames()

            // Run Vision analysis
            if let observations = try? analyzer.analyze(imageURL: frameURL) {
                let tracked = tracker.trackFaces(observations)
                let event = VisualEvent(
                    meetingId: self.meetingId,
                    timestamp: Double(session.elapsedSeconds),
                    alignedTranscriptSegment: session.segmentCount,
                    trigger: "periodic",
                    participants: tracked
                )
                try? self.bufferWriter.writeVisual(event)
            }
        }
        capture.start()
        self.screenCapture = capture

        // 6. Start pause/sensitive mode polling
        startPauseChecking(session: session)

        // 7. Wait for stop signal
        while !shouldStop {
            try await Task.sleep(for: .milliseconds(500))
        }

        // 8. Stop everything
        try await finalize(session: session, paths: paths)
    }

    private func finalize(session: MeetingSession, paths: SessionPaths) async throws {
        session.transition(to: .finalizing)

        systemAudio?.stop()
        micCapture?.stop()
        screenCapture?.stop()
        liveTranscriber?.stop()
        pauseCheckTimer?.cancel()

        // Run batch transcription on the full recording
        let audioURL = URL(fileURLWithPath: paths.audioPath)
        if FileManager.default.fileExists(atPath: paths.audioPath) {
            let batch = BatchTranscriber()
            var segments = try await batch.transcribe(audioURL: audioURL)

            // Run batch diarisation
            let diariser = DiarisationRunner()
            let speakers = try await diariser.diarize(audioURL: audioURL)
            segments = DiarisationRunner.assignSpeakers(transcript: segments, speakers: speakers)

            // Write final transcript to session dir
            let finalTranscript = segments.map { seg in
                var s = seg
                return TranscriptSegment(
                    meetingId: meetingId,
                    timestamp: seg.timestamp,
                    speaker: seg.speaker,
                    text: seg.text,
                    confidence: seg.confidence,
                    words: seg.words,
                    isFinal: true
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(finalTranscript)
            try data.write(to: URL(fileURLWithPath: "\(paths.rootDir)/transcript.json"))
        }

        session.transition(to: .completed)
        socketServer.stop()

        // Cleanup PID file
        try? FileManager.default.removeItem(atPath: Config.pidPath)

        // Cleanup old sessions
        try? sessionStore.cleanupOldSessions()
    }

    private func startPauseChecking(session: MeetingSession) {
        pauseCheckTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        pauseCheckTimer?.schedule(
            deadline: .now() + Config.pauseCheckInterval,
            repeating: Config.pauseCheckInterval
        )
        pauseCheckTimer?.setEventHandler { [weak self] in
            guard let self else { return }
            if self.pauseChecker.isPaused {
                session.transition(to: .paused)
                self.systemAudio?.stop()
                self.micCapture?.stop()
                self.screenCapture?.stop()
            } else if self.pauseChecker.isSensitive {
                session.transition(to: .sensitive)
                self.screenCapture?.stop()
                // Audio continues but transcript suppressed (handled in onSegment)
            } else if session.state == .paused || session.state == .sensitive {
                session.transition(to: .recording)
                try? self.systemAudio?.start()
                try? self.micCapture?.start()
                self.screenCapture?.start()
            }
        }
        pauseCheckTimer?.resume()
    }

    private func checkKeywordTriggers(_ text: String) {
        let triggerWords = ["price", "cost", "budget", "deadline", "timeline",
                            "concern", "problem", "issue", "risk", "decision"]
        let lower = text.lowercased()
        for word in triggerWords {
            if lower.contains(word) {
                screenCapture?.triggerHighFrequency(reason: "keyword_\(word)")
                break
            }
        }
    }

    private func handleCommand(_ cmd: SocketCommand) -> String {
        switch cmd {
        case .stop:
            shouldStop = true
            return "{\"status\": \"stopping\"}"
        case .status:
            return session?.statusJSON() ?? "{\"state\": \"unknown\"}"
        case .pause:
            session?.transition(to: .paused)
            return "{\"status\": \"paused\"}"
        case .resume:
            session?.transition(to: .recording)
            return "{\"status\": \"recording\"}"
        case .unknown:
            return "{\"error\": \"unknown command\"}"
        }
    }
}
```

- [ ] **Step 2: Update ClawMeeting.swift to wire up MeetingRecorder**

Replace the placeholder `run()` function in `ClawMeeting.swift`:

```swift
import Foundation

@main
struct ClawMeeting {
    static func main() async throws {
        let args = CommandLine.arguments
        let mode = args.count > 1 ? args[1] : "--help"

        switch mode {
        case "--run":
            let meetingId = args.count > 2 ? args[2] : generateMeetingId()
            let recorder = MeetingRecorder(meetingId: meetingId)
            try await recorder.run()
        case "--status":
            printStatus()
        case "--stop":
            sendStop()
        default:
            print("Usage: claw-meeting --run [meeting-id] | --status | --stop")
        }
    }

    static func printStatus() {
        // Connect to socket and send STATUS
        guard FileManager.default.fileExists(atPath: Config.socketPath) else {
            print("{\"state\": \"idle\"}")
            return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("{\"state\": \"idle\"}")
            return
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            Config.socketPath.withCString { cstr in
                _ = memcpy(ptr, cstr, min(Int(MemoryLayout.size(ofValue: addr.sun_path)), Config.socketPath.count + 1))
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            print("{\"state\": \"idle\"}")
            return
        }

        let msg = "STATUS\n"
        write(fd, msg, msg.utf8.count)

        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &buffer, buffer.count)
        if n > 0 {
            print(String(bytes: buffer[0..<n], encoding: .utf8) ?? "{\"state\": \"error\"}")
        }
    }

    static func sendStop() {
        guard FileManager.default.fileExists(atPath: Config.socketPath) else {
            print("No meeting running")
            return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            Config.socketPath.withCString { cstr in
                _ = memcpy(ptr, cstr, min(Int(MemoryLayout.size(ofValue: addr.sun_path)), Config.socketPath.count + 1))
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            print("Failed to connect to meeting worker")
            return
        }

        let msg = "STOP\n"
        write(fd, msg, msg.utf8.count)

        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count)
        if n > 0 {
            print(String(bytes: buffer[0..<n], encoding: .utf8) ?? "")
        }
    }

    static func generateMeetingId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
```

- [ ] **Step 3: Build to verify everything compiles**

```bash
cd mac-helper/claw-meeting && swift build
```
Expected: BUILD SUCCEEDED

Note: Compilation may reveal issues with FluidAudio's actual API surface differing from the wrappers. Adjust `LiveTranscriber`, `BatchTranscriber`, and `DiarisationRunner` to match FluidAudio's real API. The pattern stays the same.

- [ ] **Step 4: Commit**

```bash
git add mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift
git add mac-helper/claw-meeting/Sources/ClawMeeting/ClawMeeting.swift
git commit -m "feat(claw-meeting): add MeetingRecorder orchestrator and wire up main.swift"
```

---

## Task 11: Audio Recording to WAV

**Files:**
- Modify: `mac-helper/claw-meeting/Sources/ClawMeeting/AudioCapture/AudioMixer.swift`
- Modify: `mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift`

The AudioMixer needs to also write raw audio to a WAV file for post-meeting batch processing. MeetingRecorder must instantiate the writer and feed it audio samples.

- [ ] **Step 1: Add WAV file writer to AudioMixer**

Add to AudioMixer.swift:

```swift
/// Writes mixed audio to a WAV file for post-meeting batch transcription.
final class WAVFileWriter {
    private let fileURL: URL
    private var audioFile: AVAudioFile?
    private let format: AVAudioFormat

    init(path: String, sampleRate: Double = Config.sampleRate) throws {
        self.fileURL = URL(fileURLWithPath: path)
        self.format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 1
        )!
        self.audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func write(samples: [Float]) throws {
        guard let audioFile else { return }
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)
        try audioFile.write(from: buffer)
    }

    func close() {
        audioFile = nil
    }
}
```

- [ ] **Step 2: Wire WAVFileWriter into MeetingRecorder**

In `MeetingRecorder.run()`, add after creating the `AudioMixer`:

```swift
// Create WAV writer for post-meeting batch processing
let wavWriter = try WAVFileWriter(path: paths.audioPath)

// Update mixer callback to also write to WAV
mixer.onMixedBuffer = { [weak transcriber, weak wavWriter] samples in
    try? wavWriter?.write(samples: samples)
    Task {
        try? await transcriber?.processAudio(samples)
    }
}
```

And in `finalize()`, close the writer before batch processing:

```swift
// Close WAV writer before batch transcription
wavWriter?.close()
```

Store `wavWriter` as an instance property on `MeetingRecorder` so it's accessible in `finalize()`.

- [ ] **Step 3: Build to verify**

```bash
cd mac-helper/claw-meeting && swift build
```

- [ ] **Step 4: Commit**

```bash
git add mac-helper/claw-meeting/Sources/ClawMeeting/AudioCapture/AudioMixer.swift \
        mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift
git commit -m "feat(claw-meeting): add WAVFileWriter and wire into MeetingRecorder"
```

---

## Task 12: MeetingRecorder Unit Tests

**Files:**
- Create: `mac-helper/claw-meeting/Tests/ClawMeetingTests/MeetingRecorderTests.swift`

Test the orchestrator's non-hardware logic: command handling, keyword triggers, session state.

- [ ] **Step 1: Write tests for keyword trigger detection**

```swift
import XCTest
@testable import ClawMeeting

final class MeetingRecorderTests: XCTestCase {
    func testKeywordTriggersOnPrice() {
        let keywords = ["price", "cost", "budget", "deadline", "timeline",
                        "concern", "problem", "issue", "risk", "decision"]
        let text = "Let's talk about the price point"
        let lower = text.lowercased()
        let triggered = keywords.contains { lower.contains($0) }
        XCTAssertTrue(triggered)
    }

    func testNoKeywordTriggerOnNormalText() {
        let keywords = ["price", "cost", "budget", "deadline", "timeline",
                        "concern", "problem", "issue", "risk", "decision"]
        let text = "The weather is nice today"
        let lower = text.lowercased()
        let triggered = keywords.contains { lower.contains($0) }
        XCTAssertFalse(triggered)
    }

    func testMeetingSessionStatusJSON() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SessionPaths(
            id: "test", rootDir: tempDir.path,
            audioPath: "\(tempDir.path)/audio.wav",
            framesDir: "\(tempDir.path)/frames"
        )
        let session = MeetingSession(id: "test-001", paths: paths)
        let json = session.statusJSON()
        XCTAssertTrue(json.contains("\"state\":\"recording\""))
        XCTAssertTrue(json.contains("\"meeting_id\":\"test-001\""))
    }

    func testMeetingSessionStateTransition() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SessionPaths(
            id: "test", rootDir: tempDir.path,
            audioPath: "\(tempDir.path)/audio.wav",
            framesDir: "\(tempDir.path)/frames"
        )
        let session = MeetingSession(id: "test", paths: paths)
        XCTAssertEqual(session.state, .recording)
        session.transition(to: .paused)
        XCTAssertEqual(session.state, .paused)
        session.transition(to: .recording)
        XCTAssertEqual(session.state, .recording)
    }
}
```

- [ ] **Step 2: Run tests**

```bash
cd mac-helper/claw-meeting && swift test --filter MeetingRecorderTests
```
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add mac-helper/claw-meeting/Tests/ClawMeetingTests/MeetingRecorderTests.swift
git commit -m "test(claw-meeting): add MeetingRecorder and MeetingSession unit tests"
```

---

## Task 13: Manual Integration Test

**Files:** None (manual verification)

- [ ] **Step 1: Build the binary**

```bash
cd mac-helper/claw-meeting && swift build -c release
```

- [ ] **Step 2: Run the binary manually**

```bash
.build/release/ClawMeeting --run test-manual-001
```

Expected:
- Creates `~/.context-bridge/meeting-session/test-manual-001/` directory
- Creates `~/.context-bridge/meeting-session/test-manual-001/frames/` directory
- Writes PID to `~/.context-bridge/meeting-worker.pid`
- Creates Unix socket at `~/.context-bridge/meeting-worker.sock`
- Audio capture starts (may fail if permissions not granted — that's expected)
- Screen captures start appearing in frames/ directory

- [ ] **Step 3: Test status command from another terminal**

```bash
.build/release/ClawMeeting --status
```

Expected: JSON with state, elapsed_seconds, segment/screenshot counts.

- [ ] **Step 4: Test stop command**

```bash
.build/release/ClawMeeting --stop
```

Expected: Worker stops, PID file removed, socket removed.

- [ ] **Step 5: Verify buffer output**

```bash
cat ~/.context-bridge/meeting-buffer.jsonl | head -5
```

Expected: JSONL lines with `"type":"transcript"` and `"type":"visual"` entries.

- [ ] **Step 6: Clean up test data**

```bash
rm -rf ~/.context-bridge/meeting-session/test-manual-001/
rm -f ~/.context-bridge/meeting-buffer.jsonl
rm -f ~/.context-bridge/meeting-worker.pid
```

- [ ] **Step 7: Commit any fixes discovered during manual testing**

```bash
git add -A && git commit -m "fix(claw-meeting): fixes from manual integration testing"
```

---

## Task 14: Run All Tests

- [ ] **Step 1: Run complete test suite**

```bash
cd mac-helper/claw-meeting && swift test
```

Expected: All tests pass.

- [ ] **Step 2: Fix any failures, commit**

```bash
git add -A && git commit -m "test(claw-meeting): fix test failures from full suite run"
```

---

## Summary

After completing all 14 tasks, the `claw-meeting` binary can:

1. **Capture audio** — system audio (Core Audio HAL tap) + microphone (AVAudioEngine)
2. **Transcribe live** — FluidAudio + Parakeet TDT streaming with VAD
3. **Transcribe batch** — high-quality post-meeting Parakeet batch
4. **Diarise** — LS-EEND streaming + Pyannote batch speaker labels
5. **Capture screenshots** — periodic + event-triggered via CGWindowListCreateImage
6. **Analyze faces** — Apple Vision landmarks, body pose, geometric expression signals
7. **Track faces** — stable IDs across frames (grid-position based, ArcFace deferred)
8. **Write output** — JSONL buffer for daemon pickup, session directory for raw data
9. **Handle pause/sensitive** — respects existing ClawRelay privacy controls
10. **Accept commands** — Unix socket for stop/status/pause from ClawRelay
11. **Record to WAV** — raw audio saved for batch processing
12. **Auto-cleanup** — 30-day retention for local session data

**Next:** Plan 2 (ClawRelay UI integration) wires this binary into ClawRelay's menu bar, adds meeting detection, and builds the overlay panel with notification cards and sidebar.

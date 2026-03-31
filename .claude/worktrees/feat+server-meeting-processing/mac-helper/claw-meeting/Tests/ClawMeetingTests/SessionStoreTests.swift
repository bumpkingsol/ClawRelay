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

        let sessionPath = tempDir.appendingPathComponent("old-meeting").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        try store.cleanupOldSessions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
    }
}

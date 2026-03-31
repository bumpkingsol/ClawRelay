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

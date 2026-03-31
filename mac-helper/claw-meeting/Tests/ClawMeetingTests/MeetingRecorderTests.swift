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

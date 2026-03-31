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

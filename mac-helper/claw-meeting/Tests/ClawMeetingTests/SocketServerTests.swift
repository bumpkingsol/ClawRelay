import XCTest
@testable import ClawMeeting

final class SocketServerTests: XCTestCase {
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

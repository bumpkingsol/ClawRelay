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

import XCTest
@testable import OpenClawHelper

final class PermissionStatusTests: XCTestCase {
    func testMissingAccessibilityMapsToNeedsAttention() {
        let status = PermissionStatus(
            kind: .accessibility,
            state: .missing,
            detail: "Window title capture unavailable"
        )
        XCTAssertEqual(status.bannerTone, .critical)
    }

    func testGrantedMapsToOk() {
        let status = PermissionStatus(
            kind: .accessibility,
            state: .granted,
            detail: "Available"
        )
        XCTAssertEqual(status.bannerTone, .ok)
    }

    func testNeedsReviewMapsToWarning() {
        let status = PermissionStatus(
            kind: .automation,
            state: .needsReview,
            detail: "Needs review"
        )
        XCTAssertEqual(status.bannerTone, .warning)
    }
}

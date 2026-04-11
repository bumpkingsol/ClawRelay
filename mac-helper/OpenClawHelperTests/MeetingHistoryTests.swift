import XCTest
@testable import OpenClawHelper

final class MeetingHistoryTests: XCTestCase {
    func testMeetingRecordDecodesProcessingMetadata() throws {
        let data = """
        {
          "meetings": [
            {
              "id": "meeting-1",
              "started_at": "2026-04-01T10:00:00Z",
              "ended_at": "2026-04-01T10:30:00Z",
              "duration_seconds": 1800,
              "app": "Zoom",
              "participants": ["Alice"],
              "summary_md": null,
              "has_transcript": false,
              "purge_status": "summary_only",
              "processing_status": "awaiting_frames",
              "frames_expected": 6,
              "frames_uploaded": 2
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(MeetingsResponse.self, from: data)

        XCTAssertEqual(response.meetings[0].processingStatus, "awaiting_frames")
        XCTAssertEqual(response.meetings[0].framesExpected, 6)
        XCTAssertEqual(response.meetings[0].framesUploaded, 2)
    }
}

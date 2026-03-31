import XCTest
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
        XCTAssertEqual(tracked[0].faceId, "face_001")
    }
}

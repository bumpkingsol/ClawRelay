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

        // Verify it contains expected fields
        XCTAssertTrue(contents.contains("\"type\":\"transcript\""))
        XCTAssertTrue(contents.contains("\"meeting_id\":\"test-meeting\""))
        XCTAssertTrue(contents.contains("\"speaker\":\"speaker_1\""))
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
        XCTAssertTrue(contents.contains("\"face_id\":\"face_001\""))
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

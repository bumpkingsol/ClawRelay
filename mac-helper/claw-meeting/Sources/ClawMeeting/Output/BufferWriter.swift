import Foundation

// MARK: - Data Models

struct WordTiming: Codable {
    let word: String
    let start: Double
    let end: Double
}

struct TranscriptSegment: Codable {
    let meetingId: String
    let timestamp: Double
    let speaker: String
    let text: String
    let confidence: Double
    let words: [WordTiming]
    let isFinal: Bool

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case timestamp, speaker, text, confidence, words
        case isFinal = "is_final"
    }
}

struct LandmarksSummary: Codable {
    let browRaised: Bool
    let browFurrowed: Bool
    let mouthOpenness: Double

    enum CodingKeys: String, CodingKey {
        case browRaised = "brow_raised"
        case browFurrowed = "brow_furrowed"
        case mouthOpenness = "mouth_openness"
    }
}

struct ParticipantObservation: Codable {
    let faceId: String
    let gridPosition: String
    let mouthOpen: Bool
    let gaze: String
    let headTilt: Double
    let bodyLean: String
    var landmarksSummary: LandmarksSummary?

    enum CodingKeys: String, CodingKey {
        case faceId = "face_id"
        case gridPosition = "grid_position"
        case mouthOpen = "mouth_open"
        case gaze
        case headTilt = "head_tilt"
        case bodyLean = "body_lean"
        case landmarksSummary = "landmarks_summary"
    }
}

struct VisualEvent: Codable {
    let meetingId: String
    let timestamp: Double
    let alignedTranscriptSegment: Int?
    let trigger: String
    let participants: [ParticipantObservation]

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case timestamp
        case alignedTranscriptSegment = "aligned_transcript_segment"
        case trigger, participants
    }
}

// MARK: - TypedEnvelope

/// Envelope for typed JSONL entries. Flattens type + payload into one JSON object.
struct TypedEnvelope<T: Encodable>: Encodable {
    let type: String
    let payload: T

    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
    }

    enum CodingKeys: String, CodingKey {
        case type
    }
}

// MARK: - BufferWriter

final class BufferWriter {
    private let path: String
    private let encoder: JSONEncoder
    private let lock = NSLock()

    init(path: String = Config.meetingBufferPath) {
        self.path = path
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    func writeTranscript(_ segment: TranscriptSegment) throws {
        let envelope = TypedEnvelope(type: "transcript", payload: segment)
        try writeEntry(envelope)
    }

    func writeVisual(_ event: VisualEvent) throws {
        let envelope = TypedEnvelope(type: "visual", payload: event)
        try writeEntry(envelope)
    }

    private func writeEntry<T: Encodable>(_ value: T) throws {
        let data = try encoder.encode(value)
        let line = String(data: data, encoding: .utf8)! + "\n"

        lock.lock()
        defer { lock.unlock() }

        let fileHandle: FileHandle
        if FileManager.default.fileExists(atPath: path) {
            fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            fileHandle.seekToEndOfFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        }
        fileHandle.write(line.data(using: .utf8)!)
        fileHandle.closeFile()
    }
}

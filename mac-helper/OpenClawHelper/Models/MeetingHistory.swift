import Foundation

// MARK: - Server Response Models

struct MeetingsResponse: Codable {
    let meetings: [MeetingRecord]
}

struct MeetingRecord: Codable, Identifiable {
    let id: String
    let startedAt: String
    let endedAt: String?
    let durationSeconds: Int?
    let app: String?
    let participants: [String]
    let summaryMd: String?
    let hasTranscript: Bool
    let purgeStatus: String
    let processingStatus: String
    let framesExpected: Int
    let framesUploaded: Int

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case app, participants
        case summaryMd = "summary_md"
        case hasTranscript = "has_transcript"
        case purgeStatus = "purge_status"
        case processingStatus = "processing_status"
        case framesExpected = "frames_expected"
        case framesUploaded = "frames_uploaded"
    }

    var displayTitle: String {
        if let summary = summaryMd, !summary.isEmpty {
            let firstLine = summary.components(separatedBy: .newlines).first ?? summary
            let trimmed = firstLine.prefix(60)
            return String(trimmed)
        }
        return app.map { "\($0) Meeting" } ?? id
    }

    var formattedDuration: String {
        guard let secs = durationSeconds else { return "" }
        let mins = secs / 60
        return "\(mins)min"
    }

    var formattedDate: String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: startedAt) else { return startedAt }
        let display = DateFormatter()
        display.dateFormat = "E HH:mm"
        return display.string(from: date)
    }

    var captureProgressDescription: String? {
        guard framesExpected > 0 else { return nil }
        return "\(min(framesUploaded, framesExpected))/\(framesExpected) frames"
    }
}

struct ParticipantsResponse: Codable {
    let participants: [ParticipantRecord]
}

struct ParticipantRecord: Codable, Identifiable {
    let id: String
    let displayName: String
    let meetingsObserved: Int
    let lastSeen: String?
    let profile: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case meetingsObserved = "meetings_observed"
        case lastSeen = "last_seen"
        case profile
    }

    var initials: String {
        let parts = displayName.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(displayName.prefix(2)).uppercased()
    }

    var oneLiner: String {
        if let decisionStyle = profile?["decision_style"]?.stringValue, !decisionStyle.isEmpty {
            return String(decisionStyle.prefix(50))
        }
        if let nestedPatterns = profile?["patterns"]?.objectValue,
           let decisionStyle = nestedPatterns["decision_style"]?.stringValue,
           !decisionStyle.isEmpty {
            return String(decisionStyle.prefix(50))
        }
        return ""
    }
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case let .array(values):
            let rendered = values.compactMap(\.stringValue)
            return rendered.isEmpty ? nil : rendered.joined(separator: ", ")
        case let .object(value):
            return value.values.compactMap(\.stringValue).joined(separator: " ")
        case .null:
            return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }
}

struct TranscriptResponse: Codable {
    let transcript: [TranscriptSegment]?
    let visualEvents: [VisualEvent]?
    let expressionAnalysis: [ExpressionEntry]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case transcript
        case visualEvents = "visual_events"
        case expressionAnalysis = "expression_analysis"
        case error
    }
}

struct TranscriptSegment: Codable, Identifiable {
    var id: String { "\(ts)-\(speaker)" }
    let ts: String
    let speaker: String
    let text: String
}

struct VisualEvent: Codable {
    let ts: String
    let type: String
    let description: String?
}

struct ExpressionEntry: Codable {
    let ts: String
    let expression: String
    let confidence: Double
}

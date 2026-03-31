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

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case app, participants
        case summaryMd = "summary_md"
        case hasTranscript = "has_transcript"
        case purgeStatus = "purge_status"
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
}

struct ParticipantsResponse: Codable {
    let participants: [ParticipantRecord]
}

struct ParticipantRecord: Codable, Identifiable {
    let id: String
    let displayName: String
    let meetingsObserved: Int
    let lastSeen: String?
    let profile: [String: String]?

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
        profile?["decision_style"].map { String($0.prefix(50)) } ?? ""
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

import Foundation

struct BriefingPackage: Codable, Equatable {
    let meetingId: String
    let attendees: [String]
    let topic: String
    let cards: [BriefingCard]
    let participantProfiles: [String: ParticipantProfile]?
    let talkingPoints: [String]?

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case attendees, topic, cards
        case participantProfiles = "participant_profiles"
        case talkingPoints = "talking_points"
    }
}

struct BriefingCard: Codable, Equatable, Identifiable {
    let triggerKeywords: [String]
    let title: String
    let body: String
    let priority: String
    let category: String

    var id: String { title }

    enum CodingKeys: String, CodingKey {
        case triggerKeywords = "trigger_keywords"
        case title, body, priority, category
    }

    func matches(transcriptText: String) -> Bool {
        let lowered = transcriptText.lowercased()
        return triggerKeywords.contains { keyword in
            lowered.contains(keyword.lowercased())
        }
    }
}

struct ParticipantProfile: Codable, Equatable {
    let decisionStyle: String?
    let stressTriggers: [String]?
    let framingAdvice: String?

    enum CodingKeys: String, CodingKey {
        case decisionStyle = "decision_style"
        case stressTriggers = "stress_triggers"
        case framingAdvice = "framing_advice"
    }
}

import Foundation

// Note: Handoff model already exists in Handoff.swift — reused here (same module)
struct DashboardData: Decodable {
    let status: DashboardStatus
    let timeAllocation: [ProjectTime]
    let neglected: [ProjectNeglect]
    let jcActivity: [JCWorkEntry]
    let handoffs: [Handoff]  // uses existing Handoff model from Handoff.swift
    let jcQuestions: [JCQuestion]?
    let history: [DailyEntry]?

    enum CodingKeys: String, CodingKey {
        case status
        case timeAllocation = "time_allocation"
        case neglected
        case jcActivity = "jc_activity"
        case handoffs
        case jcQuestions = "jc_questions"
        case history
    }
}

struct DashboardStatus: Decodable {
    let currentApp: String
    let currentProject: String
    let idleState: String
    let idleSeconds: Int
    let inCall: Bool
    let focusMode: String?
    let focusLevel: String
    let focusSwitchesPerHour: Double
    let daemonStale: Bool
    let lastActivity: String?

    enum CodingKeys: String, CodingKey {
        case currentApp = "current_app"
        case currentProject = "current_project"
        case idleState = "idle_state"
        case idleSeconds = "idle_seconds"
        case inCall = "in_call"
        case focusMode = "focus_mode"
        case focusLevel = "focus_level"
        case focusSwitchesPerHour = "focus_switches_per_hour"
        case daemonStale = "daemon_stale"
        case lastActivity = "last_activity"
    }
}

struct ProjectTime: Decodable, Identifiable {
    var id: String { project }
    let project: String
    let hours: Double
    let percentage: Int
}

struct ProjectNeglect: Decodable, Identifiable {
    var id: String { project }
    let project: String
    let days: Int
}

struct JCWorkEntry: Decodable, Identifiable {
    let id: Int
    let project: String
    let description: String
    let status: String
    let startedAt: String
    let completedAt: String?
    let durationMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case id, project, description, status
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationMinutes = "duration_minutes"
    }
}

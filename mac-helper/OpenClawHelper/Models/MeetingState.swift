import Foundation

enum MeetingLifecycleState: String, Codable, Equatable {
    case idle
    case awaitingConsent
    case preparing
    case recording
    case finalizing
    case failed

    var displayLabel: String {
        switch self {
        case .idle:             return "Idle"
        case .awaitingConsent:  return "Consent Pending"
        case .preparing:        return "Preparing..."
        case .recording:        return "Recording"
        case .finalizing:       return "Finalizing..."
        case .failed:           return "Capture Failed"
        }
    }

    var isActive: Bool {
        self == .recording || self == .preparing || self == .finalizing
    }

    var systemImage: String {
        switch self {
        case .idle:             return "mic.slash"
        case .awaitingConsent:  return "questionmark.circle"
        case .preparing:        return "mic.badge.xmark"
        case .recording:        return "mic.fill"
        case .finalizing:       return "waveform"
        case .failed:           return "exclamationmark.mic"
        }
    }

    var tintColor: String {
        switch self {
        case .idle:             return "secondary"
        case .awaitingConsent:  return "orange"
        case .preparing:        return "orange"
        case .recording:        return "red"
        case .finalizing:       return "blue"
        case .failed:           return "red"
        }
    }
}

struct MeetingSessionInfo: Codable, Equatable {
    let meetingId: String
    let startedAt: Date
    var app: String?
    var transcriptSegments: Int
    var screenshotsTaken: Int
    var briefingLoaded: Bool
    var cardsSurfaced: Int
    var workerPid: Int32?
}

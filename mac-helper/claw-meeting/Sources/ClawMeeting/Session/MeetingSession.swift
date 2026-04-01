import Foundation

/// Holds all state for a running meeting capture session.
final class MeetingSession {
    let id: String
    let startedAt: Date
    let paths: SessionPaths
    let callApp: String?
    let allowExternalProcessing: Bool

    private(set) var segmentCount = 0
    private(set) var frameCount = 0
    private(set) var state: SessionState = .recording
    private(set) var sensitiveModeUsed = false
    private(set) var participants: [String] = []

    enum SessionState: String {
        case recording
        case paused
        case sensitive
        case finalizing
        case completed
    }

    init(
        id: String,
        paths: SessionPaths,
        callApp: String? = ProcessInfo.processInfo.environment["CB_CALL_APP"],
        allowExternalProcessing: Bool = false
    ) {
        self.id = id
        self.startedAt = Date()
        self.paths = paths
        self.callApp = callApp
        self.allowExternalProcessing = allowExternalProcessing
    }

    var elapsedSeconds: Int {
        Int(Date().timeIntervalSince(startedAt))
    }

    func incrementSegments() { segmentCount += 1 }
    func incrementFrames() { frameCount += 1 }

    func statusJSON() -> String {
        """
        {"state":"\(state.rawValue)","meeting_id":"\(id)","elapsed_seconds":\(elapsedSeconds),\
        "transcript_segments":\(segmentCount),"screenshots_taken":\(frameCount)}
        """
    }

    func transition(to newState: SessionState) {
        state = newState
        if newState == .sensitive {
            sensitiveModeUsed = true
        }
    }

    func setParticipants(_ names: [String]) {
        participants = names
    }
}

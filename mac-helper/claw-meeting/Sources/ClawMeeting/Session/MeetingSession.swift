import Foundation

/// Holds all state for a running meeting capture session.
final class MeetingSession {
    let id: String
    let startedAt: Date
    let paths: SessionPaths

    private(set) var segmentCount = 0
    private(set) var frameCount = 0
    private(set) var state: SessionState = .recording

    enum SessionState: String {
        case recording
        case paused
        case sensitive
        case finalizing
        case completed
    }

    init(id: String, paths: SessionPaths) {
        self.id = id
        self.startedAt = Date()
        self.paths = paths
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
    }
}

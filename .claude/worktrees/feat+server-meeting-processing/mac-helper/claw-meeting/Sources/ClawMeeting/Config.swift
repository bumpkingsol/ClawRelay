import Foundation

enum Config {
    static let bridgeDir = "\(NSHomeDirectory())/.context-bridge"
    static let meetingBufferPath = "\(bridgeDir)/meeting-buffer.jsonl"
    static let sessionDir = "\(bridgeDir)/meeting-session"
    static let briefingDir = "\(bridgeDir)/meeting-briefing"
    static let pidPath = "\(bridgeDir)/meeting-worker.pid"
    static let socketPath = "\(bridgeDir)/meeting-worker.sock"
    static let pauseUntilPath = "\(bridgeDir)/pause-until"
    static let sensitiveModePath = "\(bridgeDir)/sensitive-mode"
    static let modelCacheDir = "\(NSHomeDirectory())/Library/Application Support/ClawRelay/models"

    static let screenshotIntervalBaseline: TimeInterval = 30.0
    static let screenshotIntervalTriggered: TimeInterval = 5.0
    static let pauseCheckInterval: TimeInterval = 10.0
    static let sampleRate: Double = 16000.0
}

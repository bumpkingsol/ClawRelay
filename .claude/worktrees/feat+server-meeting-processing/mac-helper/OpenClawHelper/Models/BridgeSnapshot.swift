import Foundation

struct BridgeSnapshot: Decodable, Equatable {
    enum TrackingState: String, Decodable {
        case active, paused, sensitive, needsAttention

        var menuBarSymbol: String {
            switch self {
            case .active: return "eye.circle.fill"
            case .paused: return "pause.circle.fill"
            case .sensitive: return "hand.raised.circle.fill"
            case .needsAttention: return "exclamationmark.triangle.fill"
            }
        }
    }

    var trackingState: TrackingState
    var pauseUntil: String?
    var sensitiveMode: Bool
    var queueDepth: Int
    var daemonLaunchdState: String
    var watcherLaunchdState: String
    var whatsappLaunchdState: String?

    static let placeholder = BridgeSnapshot(
        trackingState: .active,
        pauseUntil: nil,
        sensitiveMode: false,
        queueDepth: 0,
        daemonLaunchdState: "unknown",
        watcherLaunchdState: "unknown",
        whatsappLaunchdState: nil
    )

    static let needsAttentionPlaceholder = BridgeSnapshot(
        trackingState: .needsAttention,
        pauseUntil: nil,
        sensitiveMode: false,
        queueDepth: 0,
        daemonLaunchdState: "unknown",
        watcherLaunchdState: "unknown",
        whatsappLaunchdState: nil
    )
}

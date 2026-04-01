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

    enum ProductState: String, Decodable {
        case running, stopped
    }

    var productState: ProductState
    var trackingState: TrackingState
    var pauseUntil: String?
    var sensitiveMode: Bool
    var queueDepth: Int
    var daemonLaunchdState: String
    var watcherLaunchdState: String
    var whatsappLaunchdState: String?
    var meetingState: String?
    var meetingId: String?
    var meetingElapsedSeconds: Int?
    var meetingWorkerPid: Int?

    var totalServiceCount: Int {
        whatsappLaunchdState != nil ? 3 : 2
    }

    var healthyServiceCount: Int {
        var count = 0
        if daemonLaunchdState == "loaded" { count += 1 }
        if watcherLaunchdState == "loaded" { count += 1 }
        if let wa = whatsappLaunchdState, wa == "loaded" { count += 1 }
        return count
    }

    var healthSummary: String {
        "\(healthyServiceCount)/\(totalServiceCount) services healthy"
    }

    var isFullyHealthy: Bool {
        healthyServiceCount == totalServiceCount && queueDepth <= 10
    }

    var isProductRunning: Bool {
        productState == .running
    }

    var isProductStopped: Bool {
        productState == .stopped
    }

    init(
        productState: ProductState = .running,
        trackingState: TrackingState,
        pauseUntil: String?,
        sensitiveMode: Bool,
        queueDepth: Int,
        daemonLaunchdState: String,
        watcherLaunchdState: String,
        whatsappLaunchdState: String? = nil,
        meetingState: String? = nil,
        meetingId: String? = nil,
        meetingElapsedSeconds: Int? = nil,
        meetingWorkerPid: Int? = nil
    ) {
        self.productState = productState
        self.trackingState = trackingState
        self.pauseUntil = pauseUntil
        self.sensitiveMode = sensitiveMode
        self.queueDepth = queueDepth
        self.daemonLaunchdState = daemonLaunchdState
        self.watcherLaunchdState = watcherLaunchdState
        self.whatsappLaunchdState = whatsappLaunchdState
        self.meetingState = meetingState
        self.meetingId = meetingId
        self.meetingElapsedSeconds = meetingElapsedSeconds
        self.meetingWorkerPid = meetingWorkerPid
    }

    private enum CodingKeys: String, CodingKey {
        case productState
        case trackingState
        case pauseUntil
        case sensitiveMode
        case queueDepth
        case daemonLaunchdState
        case watcherLaunchdState
        case whatsappLaunchdState
        case meetingState
        case meetingId
        case meetingElapsedSeconds
        case meetingWorkerPid
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackingState = try container.decode(TrackingState.self, forKey: .trackingState)
        pauseUntil = try container.decodeIfPresent(String.self, forKey: .pauseUntil)
        sensitiveMode = try container.decode(Bool.self, forKey: .sensitiveMode)
        queueDepth = try container.decode(Int.self, forKey: .queueDepth)
        daemonLaunchdState = try container.decode(String.self, forKey: .daemonLaunchdState)
        watcherLaunchdState = try container.decode(String.self, forKey: .watcherLaunchdState)
        whatsappLaunchdState = try container.decodeIfPresent(String.self, forKey: .whatsappLaunchdState)
        meetingState = try container.decodeIfPresent(String.self, forKey: .meetingState)
        meetingId = try container.decodeIfPresent(String.self, forKey: .meetingId)
        meetingElapsedSeconds = try container.decodeIfPresent(Int.self, forKey: .meetingElapsedSeconds)
        meetingWorkerPid = try container.decodeIfPresent(Int.self, forKey: .meetingWorkerPid)
        productState = try container.decodeIfPresent(ProductState.self, forKey: .productState)
            ?? ((daemonLaunchdState == "missing" && watcherLaunchdState == "missing") ? .stopped : .running)
    }

    static let placeholder = BridgeSnapshot(
        productState: .running,
        trackingState: .active,
        pauseUntil: nil,
        sensitiveMode: false,
        queueDepth: 0,
        daemonLaunchdState: "unknown",
        watcherLaunchdState: "unknown",
        whatsappLaunchdState: nil,
        meetingState: nil,
        meetingId: nil,
        meetingElapsedSeconds: nil,
        meetingWorkerPid: nil
    )

    static let needsAttentionPlaceholder = BridgeSnapshot(
        productState: .running,
        trackingState: .needsAttention,
        pauseUntil: nil,
        sensitiveMode: false,
        queueDepth: 0,
        daemonLaunchdState: "unknown",
        watcherLaunchdState: "unknown",
        whatsappLaunchdState: nil,
        meetingState: nil,
        meetingId: nil,
        meetingElapsedSeconds: nil,
        meetingWorkerPid: nil
    )

    var parsedMeetingState: MeetingLifecycleState {
        guard let raw = meetingState else { return .idle }
        return MeetingLifecycleState(rawValue: raw) ?? .idle
    }
}

import SwiftUI

// MARK: - BridgeSnapshot (placeholder until Task 5)

struct BridgeSnapshot {
    enum TrackingState: String {
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

    var trackingState: TrackingState = .active

    static let placeholder = BridgeSnapshot()
}

// MARK: - AppModel

final class AppModel: ObservableObject {
    @Published var snapshot: BridgeSnapshot = .placeholder

    var menuBarSymbol: String { snapshot.trackingState.menuBarSymbol }
}

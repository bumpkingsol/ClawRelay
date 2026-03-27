import Foundation

struct PermissionStatus: Equatable {
    enum Kind: String, CaseIterable {
        case accessibility, automation, fullDiskAccess
    }

    enum State: Equatable {
        case granted, missing, needsReview
    }

    let kind: Kind
    let state: State
    let detail: String

    var bannerTone: BannerTone {
        switch state {
        case .granted: return .ok
        case .missing: return .critical
        case .needsReview: return .warning
        }
    }

    enum BannerTone {
        case ok, warning, critical
    }
}

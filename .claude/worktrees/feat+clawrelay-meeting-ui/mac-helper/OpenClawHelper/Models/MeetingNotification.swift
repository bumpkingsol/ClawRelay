import Foundation

struct MeetingNotification: Identifiable, Equatable {
    let id: UUID
    let card: BriefingCard
    let triggeredAt: Date
    let triggerKeyword: String
    var isPinned: Bool
    var dismissAt: Date

    init(card: BriefingCard, triggerKeyword: String) {
        self.id = UUID()
        self.card = card
        self.triggeredAt = Date()
        self.triggerKeyword = triggerKeyword
        self.isPinned = false
        self.dismissAt = Date().addingTimeInterval(8.0)
    }

    var isExpired: Bool {
        !isPinned && Date() >= dismissAt
    }

    var remainingSeconds: TimeInterval {
        isPinned ? .infinity : max(0, dismissAt.timeIntervalSince(Date()))
    }
}

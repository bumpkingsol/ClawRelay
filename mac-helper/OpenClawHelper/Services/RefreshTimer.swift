import Foundation

final class RefreshTimer {
    private var timer: Timer?
    private let interval: TimeInterval
    private let action: () -> Void

    init(interval: TimeInterval = 5.0, action: @escaping () -> Void) {
        self.interval = interval
        self.action = action
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.action()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

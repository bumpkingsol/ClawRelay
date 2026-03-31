import AppKit
import Foundation

final class ScreenCapture {
    private var timer: DispatchSourceTimer?
    private var currentInterval: TimeInterval
    private let framesDir: String
    private var frameCount = 0
    private var triggeredUntil: Date?

    var onCapture: ((URL, Int) -> Void)?

    init(framesDir: String, baselineInterval: TimeInterval = Config.screenshotIntervalBaseline) {
        self.framesDir = framesDir
        self.currentInterval = baselineInterval
    }

    func start() {
        scheduleNextCapture()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func triggerHighFrequency(reason: String) {
        triggeredUntil = Date().addingTimeInterval(30)
    }

    private func scheduleNextCapture() {
        let interval: TimeInterval
        if let until = triggeredUntil, until > Date() {
            interval = Config.screenshotIntervalTriggered
        } else {
            triggeredUntil = nil
            interval = Config.screenshotIntervalBaseline
        }

        // Cancel previous timer to avoid leaking DispatchSource timers
        timer?.cancel()

        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer?.schedule(deadline: .now() + interval)
        timer?.setEventHandler { [weak self] in
            self?.captureFrame()
            self?.scheduleNextCapture()
        }
        timer?.resume()
    }

    private func captureFrame() {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming]
        ) else { return }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return }

        frameCount += 1
        let filename = String(format: "frame_%05d.png", frameCount)
        let path = "\(framesDir)/\(filename)"

        try? pngData.write(to: URL(fileURLWithPath: path))
        onCapture?(URL(fileURLWithPath: path), frameCount)
    }
}

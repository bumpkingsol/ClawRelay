import Foundation

final class PauseSensitiveChecker {
    private let pausePath: String
    private let sensitivePath: String
    private let formatter = ISO8601DateFormatter()

    init(
        pausePath: String = Config.pauseUntilPath,
        sensitivePath: String = Config.sensitiveModePath
    ) {
        self.pausePath = pausePath
        self.sensitivePath = sensitivePath
    }

    var isPaused: Bool {
        guard let content = try? String(contentsOfFile: pausePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        guard let pauseUntil = formatter.date(from: content) else {
            // Also handle Unix timestamp format
            if let ts = Double(content) {
                return Date(timeIntervalSince1970: ts) > Date()
            }
            return false
        }
        return pauseUntil > Date()
    }

    var isSensitive: Bool {
        FileManager.default.fileExists(atPath: sensitivePath)
    }
}

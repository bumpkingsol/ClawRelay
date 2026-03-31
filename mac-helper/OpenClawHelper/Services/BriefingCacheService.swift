import Foundation
import Combine

@MainActor
final class BriefingCacheService: ObservableObject {
    @Published private(set) var currentBriefing: BriefingPackage?
    @Published private(set) var activeNotifications: [MeetingNotification] = []
    @Published private(set) var firedCards: Set<String> = []

    private let briefingDir: String
    private let bufferPath: String
    private var bufferWatcherTask: Task<Void, Never>?
    private var dismissTimer: Timer?
    private let deduplicationWindow: TimeInterval = 300.0
    private var cardLastFired: [String: Date] = [:]

    init(
        briefingDir: String = "\(NSHomeDirectory())/.context-bridge/meeting-briefing",
        bufferPath: String = "\(NSHomeDirectory())/.context-bridge/meeting-buffer.jsonl"
    ) {
        self.briefingDir = briefingDir
        self.bufferPath = bufferPath
    }

    func loadBriefing(meetingId: String) {
        let path = "\(briefingDir)/\(meetingId).json"
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let briefing = try? JSONDecoder().decode(BriefingPackage.self, from: data) else {
            loadMostRecentBriefing()
            return
        }
        currentBriefing = briefing
    }

    func startBufferWatch() {
        bufferWatcherTask?.cancel()
        bufferWatcherTask = Task { [weak self] in
            guard let self else { return }
            var lastOffset: UInt64 = 0

            if let attrs = try? FileManager.default.attributesOfItem(atPath: self.bufferPath),
               let size = attrs[.size] as? UInt64 {
                lastOffset = size
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }

                guard let handle = FileHandle(forReadingAtPath: self.bufferPath) else { continue }
                defer { handle.closeFile() }

                let fileSize = handle.seekToEndOfFile()
                guard fileSize > lastOffset else { continue }

                handle.seek(toFileOffset: lastOffset)
                let newData = handle.readDataToEndOfFile()
                lastOffset = fileSize

                guard let text = String(data: newData, encoding: .utf8) else { continue }
                let lines = text.split(separator: "\n")

                for line in lines {
                    self.processTranscriptLine(String(line))
                }
            }
        }

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneExpiredNotifications()
            }
        }
    }

    func stopBufferWatch() {
        bufferWatcherTask?.cancel()
        bufferWatcherTask = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    func pinNotification(_ id: UUID) {
        if let index = activeNotifications.firstIndex(where: { $0.id == id }) {
            activeNotifications[index].isPinned = true
        }
    }

    func dismissNotification(_ id: UUID) {
        activeNotifications.removeAll { $0.id == id }
    }

    func reset() {
        currentBriefing = nil
        activeNotifications = []
        firedCards = []
        cardLastFired = [:]
        stopBufferWatch()
    }

    private func processTranscriptLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "transcript",
              let text = json["text"] as? String else { return }
        matchKeywords(transcriptText: text)
    }

    private func matchKeywords(transcriptText: String) {
        guard let briefing = currentBriefing else { return }

        for card in briefing.cards {
            if let lastFired = cardLastFired[card.title],
               Date().timeIntervalSince(lastFired) < deduplicationWindow {
                continue
            }

            if card.matches(transcriptText: transcriptText) {
                let matchedKeyword = card.triggerKeywords.first { kw in
                    transcriptText.lowercased().contains(kw.lowercased())
                } ?? ""

                let notification = MeetingNotification(card: card, triggerKeyword: matchedKeyword)
                activeNotifications.append(notification)
                firedCards.insert(card.title)
                cardLastFired[card.title] = Date()
            }
        }
    }

    private func pruneExpiredNotifications() {
        activeNotifications.removeAll { $0.isExpired }
    }

    private func loadMostRecentBriefing() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: briefingDir) else { return }
        let jsonFiles = files.filter { $0.hasSuffix(".json") }.sorted().reversed()
        guard let mostRecent = jsonFiles.first else { return }

        let path = "\(briefingDir)/\(mostRecent)"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let briefing = try? JSONDecoder().decode(BriefingPackage.self, from: data) else { return }
        currentBriefing = briefing
    }
}

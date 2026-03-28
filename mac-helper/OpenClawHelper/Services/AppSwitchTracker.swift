import AppKit
import Foundation

final class AppSwitchTracker {
    static let shared = AppSwitchTracker()

    private let logPath: String
    private let pausePath: String
    private let dateFormatter: ISO8601DateFormatter

    private init() {
        let home = NSHomeDirectory()
        logPath = "\(home)/.context-bridge/app-switches.jsonl"
        pausePath = "\(home)/.context-bridge/pause-until"
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard !isPaused() else { return }

        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let appName = app.localizedName else { return }

        let title = captureWindowTitle(appName)

        let entry: [String: Any] = [
            "ts": dateFormatter.string(from: Date()),
            "app": appName,
            "title": title,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8) else { return }

        appendLine(line)
    }

    private func captureWindowTitle(_ appName: String) -> String {
        let escaped = appName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"System Events\" to get name of front window of application process \"\(escaped)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func appendLine(_ line: String) {
        let fileURL = URL(fileURLWithPath: logPath)

        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.seekToEndOfFile()
        handle.write((line + "\n").data(using: .utf8)!)
        handle.closeFile()

        pruneOldEntries()
    }

    private func pruneOldEntries() {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let cutoff = Date().addingTimeInterval(-300)

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]

        let kept = lines.filter { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tsStr = obj["ts"] as? String,
                  let ts = fmt.date(from: tsStr) else {
                return false
            }
            return ts > cutoff
        }

        let newContent = kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
        try? newContent.write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    private func isPaused() -> Bool {
        guard let content = try? String(contentsOfFile: pausePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        if content == "indefinite" { return true }
        guard let until = TimeInterval(content) else { return false }
        return Date().timeIntervalSince1970 < until
    }
}

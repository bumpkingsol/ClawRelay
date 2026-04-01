import Foundation
import AppKit

protocol AppLifecycleControlling {
    func quit()
    func relaunch()
}

final class AppLifecycleService: AppLifecycleControlling {
    func quit() {
        NSApp.terminate(nil)
    }

    func relaunch() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
            NSApp.terminate(nil)
        }
    }
}

enum BridgeCommandError: Error {
    case actionFailed(action: String, exitCode: Int32, message: String?)
    case statusUnavailable
}

extension BridgeCommandError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .actionFailed(_, _, message):
            return message ?? "Bridge command failed"
        case .statusUnavailable:
            return "Bridge status unavailable"
        }
    }
}

private struct BridgeErrorPayload: Decodable {
    let error: String?
    let message: String?
    let status: String?
}

final class BridgeCommandRunner {
    private let executablePath: String

    init(executablePath: String = ProcessInfo.processInfo.environment["OPENCLAW_HELPERCTL_PATH"]
         ?? "\(NSHomeDirectory())/.context-bridge/bin/context-helperctl.sh") {
        self.executablePath = executablePath
    }

    private func execute(_ action: String, _ args: [String]) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [executablePath, action] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    private func bridgeErrorMessage(from data: Data, fallbackAction action: String, exitCode: Int32) -> String {
        if let payload = try? JSONDecoder().decode(BridgeErrorPayload.self, from: data) {
            if let message = payload.message, !message.isEmpty {
                return message
            }
            if let error = payload.error, !error.isEmpty {
                return error
            }
        }
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return "\(action) failed (exit \(exitCode))"
    }

    func fetchStatus() -> BridgeSnapshot {
        do {
            let (status, data) = try execute("status", [])
            guard status == 0 else {
                return .needsAttentionPlaceholder
            }
            return try JSONDecoder().decode(BridgeSnapshot.self, from: data)
        } catch {
            return .needsAttentionPlaceholder
        }
    }

    func runAction(_ action: String, _ args: String...) throws {
        let (status, data) = try execute(action, args)
        guard status == 0 else {
            throw BridgeCommandError.actionFailed(
                action: action,
                exitCode: status,
                message: bridgeErrorMessage(from: data, fallbackAction: action, exitCode: status)
            )
        }
    }

    func runActionWithOutput(_ action: String, _ args: String...) throws -> Data {
        let (status, data) = try execute(action, args)
        guard status == 0 else {
            throw BridgeCommandError.actionFailed(
                action: action,
                exitCode: status,
                message: bridgeErrorMessage(from: data, fallbackAction: action, exitCode: status)
            )
        }
        return data
    }

    func runSnapshotAction(_ action: String, _ args: String...) throws -> BridgeSnapshot {
        let (status, data) = try execute(action, args)
        guard status == 0 else {
            throw BridgeCommandError.actionFailed(
                action: action,
                exitCode: status,
                message: bridgeErrorMessage(from: data, fallbackAction: action, exitCode: status)
            )
        }
        return try JSONDecoder().decode(BridgeSnapshot.self, from: data)
    }
}

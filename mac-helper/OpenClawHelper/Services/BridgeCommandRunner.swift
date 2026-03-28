import Foundation

enum BridgeCommandError: Error {
    case actionFailed(action: String, exitCode: Int32)
    case statusUnavailable
}

final class BridgeCommandRunner {
    private let executablePath: String

    init(executablePath: String = ProcessInfo.processInfo.environment["OPENCLAW_HELPERCTL_PATH"]
         ?? "\(NSHomeDirectory())/.context-bridge/bin/context-helperctl.sh") {
        self.executablePath = executablePath
    }

    func fetchStatus() -> BridgeSnapshot {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [executablePath, "status"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return .needsAttentionPlaceholder
            }
            return try JSONDecoder().decode(BridgeSnapshot.self, from: data)
        } catch {
            return .needsAttentionPlaceholder
        }
    }

    func runAction(_ action: String, _ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [executablePath, action] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeCommandError.actionFailed(action: action, exitCode: process.terminationStatus)
        }
    }

    func runActionWithOutput(_ action: String, _ args: String...) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [executablePath, action] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeCommandError.actionFailed(action: action, exitCode: process.terminationStatus)
        }
        return data
    }
}

import Foundation

/// Manages the claw-meeting worker process lifecycle.
@MainActor
final class MeetingWorkerManager: ObservableObject {
    enum WorkerHealth: Equatable {
        case idle
        case running
        case launchFailed(String)
        case restartedAfterCrash
        case restartFailed(String)
        case stoppedIntentionally
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var workerPid: Int32? = nil
    @Published private(set) var health: WorkerHealth = .idle

    private var process: Process?
    private var monitorTask: Task<Void, Never>?
    private var stopRequested = false

    private let binaryPath: String
    private let pidPath: String
    private let socketPath: String

    init(
        binaryPath: String? = nil,
        pidPath: String = "\(NSHomeDirectory())/.context-bridge/meeting-worker.pid",
        socketPath: String = "\(NSHomeDirectory())/.context-bridge/meeting-worker.sock"
    ) {
        self.binaryPath = binaryPath
            ?? "\(NSHomeDirectory())/.context-bridge/bin/claw-meeting"
        self.pidPath = pidPath
        self.socketPath = socketPath
    }

    func startWorker(meetingId: String) throws {
        guard !isRunning else { return }

        cleanupOrphanedWorker()
        stopRequested = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["--run", meetingId]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle(forWritingAtPath: "/tmp/claw-meeting-error.log")
            ?? FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            health = .launchFailed(error.localizedDescription)
            throw error
        }
        process = proc
        workerPid = proc.processIdentifier
        isRunning = true
        health = .running

        try String(proc.processIdentifier).write(
            toFile: pidPath, atomically: true, encoding: .utf8
        )

        startMonitoring(meetingId: meetingId)
    }

    func stopWorker() {
        stopRequested = true
        health = .stoppedIntentionally
        sendSocketCommand("stop")

        Task {
            try? await Task.sleep(for: .seconds(10))
            if self.isRunning {
                self.forceKill()
            }
        }
    }

    func pauseWorker() {
        sendSocketCommand("pause")
    }

    func queryStatus() -> String? {
        return sendSocketCommandWithResponse("status")
    }

    func cleanupOrphanedWorker() {
        guard let pidString = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidString) else { return }

        if kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
            usleep(500_000)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }

        try? FileManager.default.removeItem(atPath: pidPath)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func startMonitoring(meetingId: String) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let proc = self?.process else { return }
            proc.waitUntilExit()

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                let exitCode = proc.terminationStatus
                let intentionalStop = self.stopRequested
                self.process = nil
                self.isRunning = false
                self.workerPid = nil
                try? FileManager.default.removeItem(atPath: self.pidPath)

                if intentionalStop {
                    self.stopRequested = false
                    self.health = .stoppedIntentionally
                    return
                }

                if exitCode != 0 {
                    do {
                        try self.startWorker(meetingId: meetingId)
                        self.health = .restartedAfterCrash
                    } catch {
                        self.health = .restartFailed(error.localizedDescription)
                    }
                } else {
                    self.health = .idle
                }
            }
        }
    }

    private func forceKill() {
        if let pid = process?.processIdentifier {
            kill(pid, SIGKILL)
        }
        process = nil
        isRunning = false
        workerPid = nil
        stopRequested = false
        health = .stoppedIntentionally
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    private func sendSocketCommand(_ command: String) {
        let _ = sendSocketCommandWithResponse(command)
    }

    private func sendSocketCommandWithResponse(_ command: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        command.utf8CString.withUnsafeBufferPointer { buf in
            _ = write(fd, buf.baseAddress, command.utf8.count)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return nil }
        return String(bytes: buffer[0..<bytesRead], encoding: .utf8)
    }
}

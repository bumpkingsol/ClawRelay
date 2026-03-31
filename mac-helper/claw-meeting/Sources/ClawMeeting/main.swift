import FluidAudio
import Foundation

// Entry point for claw-meeting binary.
// NOTE: Using main.swift instead of @main on a struct named ClawMeeting because
// @main on a struct in a module also named ClawMeeting causes a duplicate
// _ClawMeeting_main symbol at link time (Swift 6 compiler behaviour).

func generateMeetingId() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: Date())
}

/// Send a command to a running claw-meeting worker via its Unix socket.
/// Returns the response string, or nil if no worker is running / unreachable.
func sendSocketCommand(_ command: String) -> String? {
    let socketPath = Config.socketPath

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        socketPath.withCString { cstr in
            _ = memcpy(ptr, cstr, min(sunPathSize, socketPath.count + 1))
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard connectResult == 0 else { return nil }

    // Send command
    write(fd, command, command.utf8.count)

    // Read response
    var buffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = read(fd, &buffer, buffer.count)
    guard bytesRead > 0 else { return nil }

    return String(bytes: buffer[0..<bytesRead], encoding: .utf8)
}

func printStatus() {
    if let response = sendSocketCommand("STATUS") {
        print(response)
    } else {
        // Check PID file to give better feedback
        if let pidStr = try? String(contentsOfFile: Config.pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr),
           kill(pid, 0) == 0 {
            print("{\"state\": \"running\", \"note\": \"worker running but socket unreachable\"}")
        } else {
            print("{\"state\": \"idle\"}")
        }
    }
}

func sendStop() {
    if let response = sendSocketCommand("STOP") {
        print(response)
    } else {
        // Try to kill by PID as fallback
        if let pidStr = try? String(contentsOfFile: Config.pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr) {
            if kill(pid, SIGTERM) == 0 {
                print("{\"status\": \"sent SIGTERM to pid \(pid)\"}")
            } else {
                print("{\"error\": \"no running worker found\"}")
            }
            // Clean up stale PID file
            try? FileManager.default.removeItem(atPath: Config.pidPath)
        } else {
            print("{\"error\": \"no running worker found\"}")
        }
    }
}

@available(macOS 14.2, *)
func run(meetingId: String) async throws {
    let recorder = try MeetingRecorder(meetingId: meetingId)
    try await recorder.run()
}

@available(macOS 14.2, *)
func downloadModels() async throws {
    fputs("Downloading ASR models (Parakeet TDT v3)...\n", stderr)
    let asrModels = try await AsrModels.downloadAndLoad()
    fputs("ASR models ready.\n", stderr)

    fputs("Downloading diarisation models...\n", stderr)
    let _ = try await DiarizerModels.download()
    fputs("Diarisation models ready.\n", stderr)

    // Clean up loaded models
    _ = asrModels

    fputs("All models downloaded and verified.\n", stderr)
}

// MARK: - CLI Dispatch

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "--help"

switch mode {
case "--run":
    let meetingId = args.count > 2 ? args[2] : generateMeetingId()
    if #available(macOS 14.2, *) {
        try await run(meetingId: meetingId)
    } else {
        fputs("Error: claw-meeting requires macOS 14.2 or later\n", stderr)
        exit(1)
    }
case "--download-models":
    if #available(macOS 14.2, *) {
        try await downloadModels()
    } else {
        fputs("Error: claw-meeting requires macOS 14.2 or later\n", stderr)
        exit(1)
    }
case "--status":
    printStatus()
case "--stop":
    sendStop()
default:
    print("Usage: claw-meeting --run [meeting-id] | --download-models | --status | --stop")
}

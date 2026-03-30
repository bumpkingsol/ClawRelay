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

func printStatus() {
    print("{\"state\": \"idle\"}")
}

func sendStop() {
    print("Sending stop signal...")
}

func run(meetingId: String) async throws {
    print("Starting meeting capture: \(meetingId)")
    // TODO: wire up MeetingRecorder
    try await Task.sleep(for: .seconds(Double.greatestFiniteMagnitude))
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "--help"

switch mode {
case "--run":
    let meetingId = args.count > 2 ? args[2] : generateMeetingId()
    try await run(meetingId: meetingId)
case "--status":
    printStatus()
case "--stop":
    sendStop()
default:
    print("Usage: claw-meeting --run [meeting-id] | --status | --stop")
}

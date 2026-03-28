import Foundation
import ApplicationServices

final class PermissionService {
    func checkAll() -> [PermissionStatus] {
        [
            accessibilityStatus(),
            automationStatus(),
            fullDiskAccessStatus(),
        ]
    }

    func accessibilityStatus() -> PermissionStatus {
        if AXIsProcessTrusted() {
            return PermissionStatus(
                kind: .accessibility,
                state: .granted,
                detail: "Window title and app capture available"
            )
        } else {
            return PermissionStatus(
                kind: .accessibility,
                state: .missing,
                detail: "Window title capture unavailable"
            )
        }
    }

    func automationStatus() -> PermissionStatus {
        // Automation permission (Terminal -> Chrome) cannot be checked reliably
        // from a third-party app. Best effort: try an AppleScript check.
        let script = "tell application \"System Events\" to return name of first process"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return PermissionStatus(
                    kind: .automation,
                    state: .granted,
                    detail: "System Events automation available"
                )
            }
        } catch {
            // Process launch failed; fall through to needsReview
        }
        return PermissionStatus(
            kind: .automation,
            state: .needsReview,
            detail: "Automation permission needs review"
        )
    }

    func fullDiskAccessStatus() -> PermissionStatus {
        // Check if we can read the notification DB (requires Full Disk Access)
        let notifDB = "\(NSHomeDirectory())/Library/Group Containers/group.com.apple.usernoted/db2/db"
        if FileManager.default.isReadableFile(atPath: notifDB) {
            return PermissionStatus(
                kind: .fullDiskAccess,
                state: .granted,
                detail: "Notification capture available"
            )
        }
        return PermissionStatus(
            kind: .fullDiskAccess,
            state: .needsReview,
            detail: "Full Disk Access needs review (notification capture may be unavailable)"
        )
    }
}

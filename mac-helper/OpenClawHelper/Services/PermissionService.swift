import Foundation
import ApplicationServices

final class PermissionService {
    func checkAll(snapshot: BridgeSnapshot = .placeholder) -> [PermissionStatus] {
        [
            accessibilityStatus(),
            automationStatus(snapshot: snapshot),
            fullDiskAccessStatus(),
        ]
    }

    func accessibilityStatus() -> PermissionStatus {
        // The daemon runs via Terminal/launchd, not this app.
        // Test whether window title capture actually works, rather than
        // checking this app's own AX trust status.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to get name of first application process whose frontmost is true"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return PermissionStatus(
                    kind: .accessibility,
                    state: .granted,
                    detail: "Window title and app capture available"
                )
            }
        } catch {
            // fall through
        }
        return PermissionStatus(
            kind: .accessibility,
            state: .missing,
            detail: "Window title capture unavailable — grant Accessibility to Terminal in System Settings"
        )
    }

    func automationStatus(snapshot: BridgeSnapshot) -> PermissionStatus {
        if let diagnostic = snapshot.chromeAutomationDiagnostic {
            switch diagnostic.status {
            case .available:
                return PermissionStatus(
                    kind: .automation,
                    state: .granted,
                    detail: diagnostic.detail
                )
            case .unavailable:
                return PermissionStatus(
                    kind: .automation,
                    state: .missing,
                    detail: diagnostic.detail
                )
            case .notRunning, .missing, .unlaunchable:
                return PermissionStatus(
                    kind: .automation,
                    state: .needsReview,
                    detail: diagnostic.detail
                )
            }
        }
        return PermissionStatus(
            kind: .automation,
            state: .needsReview,
            detail: "Chrome URL capture has not been verified yet"
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

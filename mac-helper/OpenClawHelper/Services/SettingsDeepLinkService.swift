import AppKit

enum SettingsDeepLinkService {
    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAutomation() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    static func openFullDiskAccess() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    static func open(for kind: PermissionStatus.Kind) {
        switch kind {
        case .accessibility: openAccessibility()
        case .automation: openAutomation()
        case .fullDiskAccess: openFullDiskAccess()
        }
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

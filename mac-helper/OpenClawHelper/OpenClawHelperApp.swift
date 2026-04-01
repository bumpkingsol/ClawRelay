import AppKit
import SwiftUI

@MainActor
final class AppPresentationController {
    static let shared = AppPresentationController()

    var onOpenControlCenter: (() -> Void)?
    var currentWindowsProvider: () -> [NSWindow] = { NSApp.windows }
    var activateApp: () -> Void = { NSApp.activate(ignoringOtherApps: true) }

    func handleLaunch() {
        guard !hasVisibleClawRelayWindow else { return }
        showControlCenter()
    }

    func handleReopen(hasVisibleWindows: Bool) {
        if hasVisibleWindows {
            focusVisibleWindows()
        } else {
            showControlCenter()
        }
    }

    func showControlCenter() {
        if let window = clawRelayWindows.first {
            window.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }

        onOpenControlCenter?()
        activateApp()
    }

    private var clawRelayWindows: [NSWindow] {
        currentWindowsProvider().filter { $0.title == "ClawRelay" }
    }

    private var hasVisibleClawRelayWindow: Bool {
        clawRelayWindows.contains(where: \.isVisible)
    }

    private func focusVisibleWindows() {
        if let window = clawRelayWindows.first(where: \.isVisible) {
            window.makeKeyAndOrderFront(nil)
        }
        activateApp()
    }
}

final class OpenClawHelperAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            AppPresentationController.shared.handleLaunch()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppPresentationController.shared.handleReopen(hasVisibleWindows: flag)
        return true
    }
}

private struct ControlCenterRootView: View {
    @ObservedObject var viewModel: ControlCenterViewModel
    @ObservedObject var meetingViewModel: MeetingViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ControlCenterView(viewModel: viewModel, meetingViewModel: meetingViewModel)
            .onAppear {
                AppPresentationController.shared.onOpenControlCenter = {
                    openWindow(id: "control-center")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

@main
struct OpenClawHelperApp: App {
    @NSApplicationDelegateAdaptor(OpenClawHelperAppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("ClawRelay", id: "control-center") {
            ControlCenterRootView(
                viewModel: appModel.controlCenterViewModel,
                meetingViewModel: appModel.meetingViewModel
            )
        }
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .windowArrangement) {
                Button("Show ClawRelay") {
                    AppPresentationController.shared.showControlCenter()
                }
                .keyboardShortcut("0")
            }
        }

        MenuBarExtra("ClawRelay", systemImage: appModel.menuBarSymbol) {
            MenuBarPopoverView(viewModel: appModel.menuBarViewModel, meetingViewModel: appModel.meetingViewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

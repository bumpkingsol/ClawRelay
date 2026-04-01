import AppKit
import SwiftUI

@MainActor
final class AppPresentationController {
    static let shared = AppPresentationController()

    var currentWindowsProvider: () -> [NSWindow] = { NSApp.windows }
    var activateApp: () -> Void = { NSApp.activate(ignoringOtherApps: true) }

    private weak var controlCenterWindow: NSWindow?

    func registerControlCenterWindow(_ window: NSWindow?) {
        controlCenterWindow = window
    }

    func handleReopen(hasVisibleWindows: Bool) -> Bool {
        if focusExistingWindow() {
            activateApp()
            return true
        }
        if hasVisibleWindows, let window = currentWindowsProvider().first {
            window.makeKeyAndOrderFront(nil)
            activateApp()
            return true
        }
        return false
    }

    func showControlCenter(openWindow: (() -> Void)? = nil) {
        if focusExistingWindow() {
            activateApp()
            return
        }

        if let openWindow {
            openWindow()
            activateApp()
        } else {
            activateApp()
        }
    }

    private func focusExistingWindow() -> Bool {
        if let window = controlCenterWindow {
            window.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }
}

final class OpenClawHelperAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppPresentationController.shared.handleReopen(hasVisibleWindows: flag)
    }
}

private struct ControlCenterRootView: View {
    @ObservedObject var viewModel: ControlCenterViewModel
    @ObservedObject var meetingViewModel: MeetingViewModel

    var body: some View {
        ControlCenterView(viewModel: viewModel, meetingViewModel: meetingViewModel)
            .background(ControlCenterWindowReader())
    }
}

private struct ControlCenterWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowTrackingView()
        view.onWindowChange = { window in
            AppPresentationController.shared.registerControlCenterWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowTrackingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private struct ControlCenterCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }

        CommandGroup(after: .windowArrangement) {
            Button("Show ClawRelay") {
                AppPresentationController.shared.showControlCenter {
                    openWindow(id: "control-center")
                }
            }
            .keyboardShortcut("0")
        }
    }
}

@main
struct OpenClawHelperApp: App {
    @NSApplicationDelegateAdaptor(OpenClawHelperAppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        Window("ClawRelay", id: "control-center") {
            ControlCenterRootView(
                viewModel: appModel.controlCenterViewModel,
                meetingViewModel: appModel.meetingViewModel
            )
        }
        .commands {
            ControlCenterCommands()
        }

        MenuBarExtra("ClawRelay", systemImage: appModel.menuBarSymbol) {
            MenuBarPopoverView(viewModel: appModel.menuBarViewModel, meetingViewModel: appModel.meetingViewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

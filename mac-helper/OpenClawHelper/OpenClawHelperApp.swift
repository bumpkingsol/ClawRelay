import AppKit
import SwiftUI

@MainActor
final class AppInstanceCoordinator {
    static let shared = AppInstanceCoordinator()
    static let showControlCenterNotification = Notification.Name("com.openclaw.clawrelay.show-control-center")

    var currentProcessIdentifier: () -> pid_t = { ProcessInfo.processInfo.processIdentifier }
    var bundleIdentifierProvider: () -> String? = { Bundle.main.bundleIdentifier }
    var runningApplicationsProvider: (String) -> [NSRunningApplication] = { bundleIdentifier in
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    }
    var postShowControlCenterRequest: (String) -> Void = { bundleIdentifier in
        DistributedNotificationCenter.default().post(
            name: AppInstanceCoordinator.showControlCenterNotification,
            object: bundleIdentifier
        )
    }
    var activateRunningApplication: (NSRunningApplication) -> Void = { application in
        application.activate(options: [.activateAllWindows])
    }
    var terminateCurrentApp: () -> Void = { NSApp.terminate(nil) }

    private var showControlCenterHandler: (() -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.showControlCenterNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard
                    let self,
                    let bundleIdentifier = notification.object as? String,
                    bundleIdentifier == self.bundleIdentifierProvider()
                else {
                    return
                }

                self.showControlCenterHandler?()
            }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    func registerShowControlCenterHandler(_ handler: @escaping () -> Void) {
        showControlCenterHandler = handler
    }

    func handleLaunch() -> Bool {
        guard let bundleIdentifier = bundleIdentifierProvider() else {
            return true
        }

        let currentProcessIdentifier = currentProcessIdentifier()
        guard let existingApplication = runningApplicationsProvider(bundleIdentifier).first(where: {
            $0.processIdentifier != currentProcessIdentifier
        }) else {
            return true
        }

        postShowControlCenterRequest(bundleIdentifier)
        activateRunningApplication(existingApplication)
        terminateCurrentApp()
        return false
    }
}

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
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = AppInstanceCoordinator.shared.handleLaunch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppPresentationController.shared.handleReopen(hasVisibleWindows: flag)
    }
}

private struct ControlCenterRootView: View {
    @ObservedObject var viewModel: ControlCenterViewModel
    @ObservedObject var meetingViewModel: MeetingViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ControlCenterView(viewModel: viewModel, meetingViewModel: meetingViewModel)
            .background(ControlCenterWindowReader())
            .onAppear {
                AppInstanceCoordinator.shared.registerShowControlCenterHandler {
                    AppPresentationController.shared.showControlCenter {
                        openWindow(id: "control-center")
                    }
                }
            }
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

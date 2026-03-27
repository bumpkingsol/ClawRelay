import SwiftUI

@main
struct OpenClawHelperApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra("OpenClaw Helper", systemImage: appModel.menuBarSymbol) {
            MenuBarPopoverView(viewModel: appModel.menuBarViewModel)
        }
        .menuBarExtraStyle(.window)

        Window("OpenClaw Control Center", id: "control-center") {
            ControlCenterView(viewModel: appModel.controlCenterViewModel)
        }
    }
}

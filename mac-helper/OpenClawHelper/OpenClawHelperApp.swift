import SwiftUI

@main
struct OpenClawHelperApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra("ClawRelay", systemImage: appModel.menuBarSymbol) {
            MenuBarPopoverView(viewModel: appModel.menuBarViewModel, meetingViewModel: appModel.meetingViewModel)
        }
        .menuBarExtraStyle(.window)

        Window("ClawRelay", id: "control-center") {
            ControlCenterView(viewModel: appModel.controlCenterViewModel, meetingViewModel: appModel.meetingViewModel)
        }
    }
}

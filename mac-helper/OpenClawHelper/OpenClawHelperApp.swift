import SwiftUI

// MARK: - Placeholder Views (replaced in Tasks 6 & 7)

struct MenuBarPopoverView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Text("Menu Bar Popover - coming in Task 6")
            .padding()
    }
}

struct ControlCenterView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Text("Control Center - coming in Task 7")
            .padding()
    }
}

// MARK: - App Entry Point

@main
struct OpenClawHelperApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra("OpenClaw Helper", systemImage: appModel.menuBarSymbol) {
            MenuBarPopoverView(appModel: appModel)
        }
        .menuBarExtraStyle(.window)

        Window("OpenClaw Control Center", id: "control-center") {
            ControlCenterView(appModel: appModel)
        }
    }
}

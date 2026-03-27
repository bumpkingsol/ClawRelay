import SwiftUI

// MARK: - Placeholder Views (replaced in Task 7)

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
            MenuBarPopoverView(viewModel: appModel.menuBarViewModel)
        }
        .menuBarExtraStyle(.window)

        Window("OpenClaw Control Center", id: "control-center") {
            ControlCenterView(appModel: appModel)
        }
    }
}

import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            StatusHeaderView(snapshot: viewModel.snapshot)
            HealthStripView(snapshot: viewModel.snapshot)
            QuickActionsGrid(viewModel: viewModel)
            Button("Open Control Center") {
                openWindow(id: "control-center")
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(DarkUtilityGlass.background)
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }
}

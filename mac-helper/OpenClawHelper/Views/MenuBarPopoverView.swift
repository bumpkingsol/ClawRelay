import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            StatusHeaderView(snapshot: viewModel.snapshot)
            HealthStripView(snapshot: viewModel.snapshot)
            QuickActionsGrid(viewModel: viewModel)
            Divider()

            // Quick handoff
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    TextField("Project", text: $viewModel.handoffProject)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                    Menu {
                        ForEach(MenuBarViewModel.portfolioProjects, id: \.self) { p in
                            Button(p.capitalized) { viewModel.handoffProject = p }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                }
                HStack(spacing: 8) {
                    TextField("What should JC do?", text: $viewModel.handoffTask)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if !viewModel.handoffTask.isEmpty {
                                viewModel.sendQuickHandoff()
                            }
                        }
                    if viewModel.handoffSent {
                        Text("Sent")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                    Button(action: { viewModel.sendQuickHandoff() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.handoffTask.isEmpty)
                }
            }
            Button("Open Control Center") {
                openWindow(id: "control-center")
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(DarkUtilityGlass.background)
        .environment(\.colorScheme, .dark)
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }
}

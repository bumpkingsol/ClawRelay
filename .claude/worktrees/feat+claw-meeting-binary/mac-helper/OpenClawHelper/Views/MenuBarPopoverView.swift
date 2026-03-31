import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            StatusHeaderView(snapshot: viewModel.snapshot)

            // Dashboard summary
            if let dash = viewModel.dashboard {
                HStack(spacing: 8) {
                    let hours = dash.timeAllocation.first(where: { $0.project == dash.status.currentProject })?.hours ?? 0
                    Text("\(dash.status.currentProject.capitalized) \(hours, specifier: "%.1f")h")
                        .font(.caption)
                        .foregroundStyle(.primary)

                    Text("|")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    if let active = dash.jcActivity.first(where: { $0.status == "in-progress" }) {
                        Text("JC: \(active.project)")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else {
                        Text("JC: idle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(dash.status.focusLevel.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(focusColor(dash.status.focusLevel).opacity(0.2), in: Capsule())
                        .foregroundStyle(focusColor(dash.status.focusLevel))
                }
                .padding(.horizontal, 4)
            }

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
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(DarkUtilityGlass.background)
        .environment(\.colorScheme, .dark)
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    private func focusColor(_ level: String) -> Color {
        switch level {
        case "focused": return .green
        case "multitasking": return .orange
        case "scattered": return .red
        default: return .secondary
        }
    }
}

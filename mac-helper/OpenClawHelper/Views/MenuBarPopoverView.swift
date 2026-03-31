import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @ObservedObject var meetingViewModel: MeetingViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            // Zone 1: Status Header
            StatusHeaderView(snapshot: viewModel.snapshot)

            // Zone 2: Health Detail Card (conditional)
            if !viewModel.snapshot.isFullyHealthy {
                HealthDetailCard(snapshot: viewModel.snapshot)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Zone 6: Meeting Status (between health and pause when active)
            if meetingViewModel.state != .idle {
                MeetingStatusView(viewModel: meetingViewModel)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Zone 3 + 4: Pause Controls & Sensitive Toggle
            QuickActionsGrid(viewModel: viewModel)

            // Divider before handoff
            DarkUtilityGlass.divider.frame(height: 1)

            // Zone 5: Handoff Section
            handoffSection

            // Zone 7: Footer
            Button(action: openControlCenter) {
                Text("Control Center \(Image(systemName: "arrow.up.right"))")
                    .font(.system(size: 11))
                    .foregroundStyle(DarkUtilityGlass.sectionLabelColor)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 340)
        .background(DarkUtilityGlass.background)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.25), value: viewModel.snapshot.trackingState)
        .animation(.easeInOut(duration: 0.25), value: viewModel.snapshot.isFullyHealthy)
        .animation(.easeInOut(duration: 0.25), value: meetingViewModel.state)
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    // MARK: - Handoff Section

    private var handoffSection: some View {
        VStack(spacing: 8) {
            // Section label
            HStack {
                Text("HANDOFF TO JC")
                    .font(DarkUtilityGlass.sectionLabel)
                    .foregroundStyle(DarkUtilityGlass.sectionLabelColor)
                    .tracking(0.8)
                Spacer()
            }

            // Project picker
            Menu {
                ForEach(MenuBarViewModel.portfolioProjects, id: \.self) { project in
                    Button(project.capitalized) {
                        viewModel.handoffProject = project
                    }
                }
            } label: {
                HStack {
                    Text(viewModel.handoffProject.isEmpty ? "Select project" : viewModel.handoffProject)
                        .font(.system(size: 11))
                        .foregroundStyle(viewModel.handoffProject.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DarkUtilityGlass.cardBackground)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)

            // Task input + send
            HStack(spacing: 6) {
                TextField("What should JC do?", text: $viewModel.handoffTask)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DarkUtilityGlass.cardBackground)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .onSubmit {
                        if !viewModel.handoffTask.isEmpty {
                            viewModel.sendQuickHandoff()
                        }
                    }

                if viewModel.handoffSent {
                    Text("Sent")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkUtilityGlass.activeGreen)
                        .transition(.opacity)
                }

                Button(action: { viewModel.sendQuickHandoff() }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DarkUtilityGlass.accentBlue)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(DarkUtilityGlass.accentBlue.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.handoffTask.isEmpty)
            }
        }
    }

    private func openControlCenter() {
        openWindow(id: "control-center")
        NSApp.activate(ignoringOtherApps: true)
    }
}

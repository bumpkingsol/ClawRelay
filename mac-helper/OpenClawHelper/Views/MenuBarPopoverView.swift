import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @ObservedObject var meetingViewModel: MeetingViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        UtilityGlassContainer(spacing: 16) {
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

                if let actionError = viewModel.actionError, !actionError.isEmpty {
                    inlineError(actionError)
                        .transition(.opacity)
                }

                // Divider before handoff
                DarkUtilityGlass.divider.frame(height: 1)

                // Zone 5: Handoff Section
                handoffSection

                // Zone 7: Footer
                footerActions
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
    }

    private var footerActions: some View {
        HStack(spacing: 12) {
            Button(action: openControlCenter) {
                Text("Control Center \(Image(systemName: "arrow.up.right"))")
                    .font(.system(size: 11))
                    .foregroundStyle(DarkUtilityGlass.sectionLabelColor)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Menu {
                Button("About ClawRelay") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }

                Button("Show ClawRelay") {
                    openControlCenter()
                }

                Divider()

                Button(viewModel.productLifecycleActionTitle) {
                    if viewModel.snapshot.isProductStopped {
                        viewModel.startProduct()
                        openControlCenter()
                    } else {
                        viewModel.shutdownProduct()
                    }
                }

                Button("Relaunch Helper") {
                    viewModel.relaunchApplication()
                }

                Divider()

                Button("Quit ClawRelay") {
                    viewModel.quitApplication()
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DarkUtilityGlass.sectionLabelColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Handoff Section

    private var pickerLabel: some View {
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
        .popoverGlassSurface(interactive: true)
    }

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
                ForEach(viewModel.portfolioProjects, id: \.self) { project in
                    Button(project.capitalized) {
                        viewModel.handoffProject = project
                    }
                }
            } label: {
                pickerLabel
            }
            .menuStyle(.button)

            // Task input + send
            HStack(spacing: 6) {
                TextField("What should JC do?", text: $viewModel.handoffTask)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .popoverGlassSurface(interactive: true)
                    .onSubmit {
                        if !viewModel.handoffTask.isEmpty {
                            viewModel.sendQuickHandoff()
                        }
                    }

                if viewModel.handoffSending {
                    Text("Sending...")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else if viewModel.handoffSent {
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
                        .popoverGlassSurface(
                            tint: DarkUtilityGlass.accentBlue.opacity(0.30),
                            fallbackFill: DarkUtilityGlass.accentBlue.opacity(0.10),
                            fallbackStroke: DarkUtilityGlass.accentBlue.opacity(0.18),
                            interactive: true
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.handoffTask.isEmpty)
            }

            if let handoffError = viewModel.handoffError, !handoffError.isEmpty {
                inlineError(handoffError)
            }
        }
    }

    private func inlineError(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.red.opacity(0.2), lineWidth: 1)
            )
    }

    private func openControlCenter() {
        AppPresentationController.shared.showControlCenter {
            openWindow(id: "control-center")
        }
    }
}

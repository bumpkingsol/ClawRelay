import SwiftUI

struct ControlCenterView: View {
    @ObservedObject var viewModel: ControlCenterViewModel
    @ObservedObject var meetingViewModel: MeetingViewModel

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ControlCenterTab.allCases) { tab in
                    Button(action: { viewModel.selectedTab = tab }) {
                        Label(tab.rawValue.capitalized, systemImage: tabIcon(tab))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(
                                viewModel.selectedTab == tab
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 180)

            Divider()

            // Detail
            Group {
                switch viewModel.selectedTab {
                case .dashboard:
                    DashboardTabView(viewModel: DashboardViewModel(runner: viewModel.runner))
                case .meetings:
                    MeetingsTabView(meetingVM: meetingViewModel)
                case .overview:
                    OverviewTabView(viewModel: viewModel)
                case .diagnostics:
                    DiagnosticsTabView(viewModel: viewModel)
                case .permissions:
                    PermissionsTabView(viewModel: viewModel)
                case .privacy:
                    PrivacyTabView(viewModel: viewModel)
                case .handoffs:
                    HandoffsTabView(viewModel: HandoffsTabViewModel(runner: viewModel.runner))
                case .none:
                    Text("Select a tab")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(DarkUtilityGlass.background)
        .environment(\.colorScheme, .dark)
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    private func tabIcon(_ tab: ControlCenterTab) -> String {
        switch tab {
        case .dashboard: return "chart.bar.xaxis"
        case .meetings: return "mic.and.signal.meter"
        case .overview: return "gauge.with.dots.needle.33percent"
        case .permissions: return "lock.shield"
        case .privacy: return "hand.raised"
        case .handoffs: return "paperplane"
        case .diagnostics: return "wrench.and.screwdriver"
        }
    }
}

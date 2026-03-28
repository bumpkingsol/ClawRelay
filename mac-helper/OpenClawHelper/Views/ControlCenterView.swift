import SwiftUI

struct ControlCenterView: View {
    @ObservedObject var viewModel: ControlCenterViewModel

    var body: some View {
        NavigationSplitView {
            List(ControlCenterTab.allCases, selection: $viewModel.selectedTab) { tab in
                Label(tab.rawValue.capitalized, systemImage: tabIcon(tab))
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch viewModel.selectedTab {
            case .overview:
                OverviewTabView(viewModel: viewModel)
            case .diagnostics:
                DiagnosticsTabView(viewModel: viewModel)
            case .permissions:
                PermissionsTabView(viewModel: viewModel)
            case .privacy:
                PrivacyTabView(viewModel: viewModel)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(DarkUtilityGlass.background)
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    private func tabIcon(_ tab: ControlCenterTab) -> String {
        switch tab {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .permissions: return "lock.shield"
        case .privacy: return "hand.raised"
        case .diagnostics: return "wrench.and.screwdriver"
        }
    }
}

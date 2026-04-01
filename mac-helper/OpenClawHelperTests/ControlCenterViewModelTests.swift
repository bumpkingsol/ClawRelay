import XCTest
@testable import OpenClawHelper

final class ControlCenterViewModelTests: XCTestCase {
    @MainActor
    func testFeatureViewModelsStayStableAcrossTabSelectionChanges() {
        let viewModel = ControlCenterViewModel()
        let dashboardViewModel = viewModel.dashboardViewModel
        let handoffsViewModel = viewModel.handoffsViewModel

        viewModel.selectedTab = .meetings
        viewModel.selectedTab = .privacy
        viewModel.selectedTab = .dashboard
        viewModel.selectedTab = .handoffs

        XCTAssertTrue(dashboardViewModel === viewModel.dashboardViewModel)
        XCTAssertTrue(handoffsViewModel === viewModel.handoffsViewModel)
    }
}

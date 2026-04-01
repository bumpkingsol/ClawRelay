import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let menuBarViewModel: MenuBarViewModel
    let controlCenterViewModel: ControlCenterViewModel
    let meetingViewModel: MeetingViewModel
    private var cancellables = Set<AnyCancellable>()

    init() {
        let runner = BridgeCommandRunner()
        let appLifecycle = AppLifecycleService()
        self.menuBarViewModel = MenuBarViewModel(runner: runner, appLifecycle: appLifecycle)
        self.controlCenterViewModel = ControlCenterViewModel(runner: runner, appLifecycle: appLifecycle)
        self.meetingViewModel = MeetingViewModel(runner: runner)

        NotificationService.shared.requestPermission()
        AppSwitchTracker.shared.start()

        // Forward changes from both view models so SwiftUI re-evaluates menuBarSymbol
        menuBarViewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        controlCenterViewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        meetingViewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    var menuBarSymbol: String {
        if meetingViewModel.state == .recording {
            return "mic.fill"
        }
        if menuBarViewModel.snapshot.isProductStopped {
            return "power.circle"
        }
        return menuBarViewModel.snapshot.trackingState.menuBarSymbol
    }
}

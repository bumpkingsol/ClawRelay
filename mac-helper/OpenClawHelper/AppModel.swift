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
        self.menuBarViewModel = MenuBarViewModel(runner: runner)
        self.controlCenterViewModel = ControlCenterViewModel(runner: runner)
        self.meetingViewModel = MeetingViewModel()

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
        return menuBarViewModel.snapshot.trackingState.menuBarSymbol
    }
}

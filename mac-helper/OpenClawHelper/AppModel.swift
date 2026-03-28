import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let menuBarViewModel: MenuBarViewModel
    let controlCenterViewModel: ControlCenterViewModel
    private var cancellables = Set<AnyCancellable>()

    init() {
        let runner = BridgeCommandRunner()
        self.menuBarViewModel = MenuBarViewModel(runner: runner)
        self.controlCenterViewModel = ControlCenterViewModel(runner: runner)

        NotificationService.shared.requestPermission()

        // Forward changes from both view models so SwiftUI re-evaluates menuBarSymbol
        menuBarViewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        controlCenterViewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    var menuBarSymbol: String { menuBarViewModel.snapshot.trackingState.menuBarSymbol }
}

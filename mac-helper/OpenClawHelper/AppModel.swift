import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let menuBarViewModel: MenuBarViewModel
    private var cancellable: AnyCancellable?

    init() {
        self.menuBarViewModel = MenuBarViewModel()
        // Forward changes from the view model so SwiftUI re-evaluates menuBarSymbol
        cancellable = menuBarViewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var menuBarSymbol: String { menuBarViewModel.snapshot.trackingState.menuBarSymbol }
}

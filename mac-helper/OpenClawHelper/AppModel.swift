import SwiftUI

final class AppModel: ObservableObject {
    @Published var snapshot: BridgeSnapshot = .placeholder

    var menuBarSymbol: String { snapshot.trackingState.menuBarSymbol }
}

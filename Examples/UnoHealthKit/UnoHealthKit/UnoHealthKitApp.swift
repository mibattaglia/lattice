import SwiftUI
import UnoArchitecture

@main
struct UnoHealthKitApp: App {
    @StateObject private var rootViewModel: AnyViewModel<RootEvent, RootViewState>

    private let healthKitReader: HealthKitReader

    init() {
        let reader = RealHealthKitReader()
        self.healthKitReader = reader

        _rootViewModel = StateObject(
            wrappedValue: RootViewModel(
                interactor: RootInteractor(healthKitReader: reader)
                    .eraseToAnyInteractor(),
                viewStateReducer: RootViewStateReducer()
                    .eraseToAnyReducer()
            )
            .erased()
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                viewModel: rootViewModel,
                healthKitReader: healthKitReader
            )
        }
    }
}

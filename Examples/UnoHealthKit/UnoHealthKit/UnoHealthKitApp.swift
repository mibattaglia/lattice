import SwiftUI
import UnoArchitecture

@main
struct UnoHealthKitApp: App {
    @State private var rootViewModel: ViewModel<RootEvent, RootDomainState, RootViewState>

    private let healthKitReader: HealthKitReader

    init() {
        let reader = RealHealthKitReader()
        self.healthKitReader = reader

        _rootViewModel = State(
            wrappedValue: ViewModel(
                initialValue: RootViewState.loading,
                RootInteractor(healthKitReader: reader)
                    .eraseToAnyInteractor(),
                RootViewStateReducer()
                    .eraseToAnyReducer()
            )
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

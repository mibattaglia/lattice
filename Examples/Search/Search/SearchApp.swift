import SwiftUI
import UnoArchitecture

@main
struct SearchApp: App {
    @StateObject private var viewModel: ViewModel<SearchInteractor, SearchViewStateReducer>

    init() {
        let weatherService = RealWeatherService()
        _viewModel = StateObject(
            wrappedValue: ViewModel(
                initialValue: SearchViewState.none,
                SearchInteractor(weatherService: weatherService)
                    .eraseToAnyInteractor(),
                SearchViewStateReducer()
                    .eraseToAnyReducer()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            SearchView(viewModel: viewModel)
        }
    }
}

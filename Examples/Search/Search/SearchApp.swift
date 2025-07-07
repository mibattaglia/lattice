import SwiftUI
import UnoArchitecture

@main
struct SearchApp: App {
    @StateObject private var viewModel: AnyViewModel<SearchEvent, SearchViewState>

    init() {
        let weatherService = RealWeatherService()
        _viewModel = StateObject(
            wrappedValue: SearchViewModel(
                interactor: SearchInteractor(weatherService: weatherService)
                    .eraseToAnyInteractor(),
                viewStateReducer: SearchViewStateReducer()
                    .eraseToAnyReducer()
            )
            .erased()
        )
    }

    var body: some Scene {
        WindowGroup {
            SearchView(viewModel: viewModel)
        }
    }
}

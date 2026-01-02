import SwiftUI
import UnoArchitecture

@main
struct SearchApp: App {
    @State private var viewModel: ViewModel<SearchEvent, SearchDomainState, SearchViewState>

    init() {
        let weatherService = RealWeatherService()
        _viewModel = State(
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

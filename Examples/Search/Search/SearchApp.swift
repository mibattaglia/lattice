import SwiftUI
import UnoArchitecture

@main
struct SearchApp: App {
    @State private var viewModel: ViewModel<SearchEvent, SearchDomainState, SearchViewState>

    init() {
        let weatherService = RealWeatherService()
        _viewModel = State(
            wrappedValue: ViewModel(
                initialValue: SearchViewState.loaded(.init(query: "", listItems: [])),
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

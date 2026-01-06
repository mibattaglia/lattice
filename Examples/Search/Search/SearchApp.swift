import SwiftUI
import UnoArchitecture

@main
struct SearchApp: App {
    @State private var viewModel: ViewModel<SearchEvent, SearchDomainState, SearchViewState>

    init() {
        let weatherService = RealWeatherService()
        _viewModel = State(
            wrappedValue: ViewModel(
                initialDomainState: .results(.init(query: "", results: [])),
                initialViewState: .loaded(.init(query: "", listItems: [])),
                interactor: SearchInteractor(weatherService: weatherService).eraseToAnyInteractor(),
                viewStateReducer: SearchViewStateReducer().eraseToAnyReducer()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            SearchView(viewModel: viewModel)
        }
    }
}

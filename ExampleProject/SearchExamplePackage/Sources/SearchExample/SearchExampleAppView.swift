import Lattice
import SwiftUI

public struct SearchExampleAppView: View {
    @State private var viewModel: ViewModel<SearchEvent, SearchDomainState, SearchViewState>

    public init() {
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

    public var body: some View {
        SearchView(viewModel: viewModel)
    }
}

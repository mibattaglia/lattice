import Lattice
import SwiftUI

public struct SearchExampleAppView: View {
    private typealias SearchFeature = Feature<SearchEvent, SearchDomainState, SearchViewState>
    @State private var viewModel: ViewModel<SearchFeature>

    public init() {
        let weatherService = RealWeatherService()
        let feature = Feature(
            interactor: SearchInteractor(weatherService: weatherService),
            reducer: SearchViewStateReducer()
        )
        _viewModel = State(
            wrappedValue: ViewModel(
                initialDomainState: .results(.init(query: "", results: [])),
                feature: feature
            )
        )
    }

    public var body: some View {
        SearchView(viewModel: viewModel)
    }
}

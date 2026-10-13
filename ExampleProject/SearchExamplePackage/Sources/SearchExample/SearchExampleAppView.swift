import Lattice
import SwiftUI

public struct SearchExampleAppView: View {
    @State private var viewModel: ViewModel<Feature<SearchEvent, SearchState>>

    public init() {
        let weatherService = RealWeatherService()
        let feature = Feature(interactor: SearchInteractor(weatherService: weatherService))
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: .results(.init(query: "", results: [])),
                feature: feature
            )
        )
    }

    public var body: some View {
        SearchView(viewModel: viewModel)
    }
}

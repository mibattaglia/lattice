import Lattice
import SwiftUI

public struct SearchExampleAppView: View {
    @State private var viewModel: ViewModel<SearchState, SearchEvent>

    public init() {
        let weatherService = RealWeatherService()
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: .results(.none),
                interactor: SearchInteractor(weatherService: weatherService)
            )
        )
    }

    public var body: some View {
        SearchView(viewModel: viewModel)
    }
}

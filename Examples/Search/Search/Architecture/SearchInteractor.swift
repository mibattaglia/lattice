import UnoArchitecture

@Interactor<SearchDomainState, SearchEvent>
struct SearchInteractor: Sendable {
    private let weatherService: WeatherService
    private let searchQueryInteractor: AnyInteractor<SearchDomainState.ResultState, SearchQueryEvent>

    init(weatherService: WeatherService) {
        self.weatherService = weatherService
        self.searchQueryInteractor = SearchQueryInteractor(weatherService: weatherService)
            .eraseToAnyInteractor()
    }

    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .searchResultsChanged(let results):
                print("results changed")
                state = .results(results)
                return .none

            case .search:
                return .none

            case .locationTapped(let id):
                guard case .results(var resultState) = state else {
                    return .none
                }

                guard let tappedRowIndex = resultState.results.firstIndex(where: {
                    "\($0.weatherModel.id)" == id
                }) else {
                    return .none
                }

                let tappedRow = resultState.results[tappedRowIndex]

                guard !tappedRow.isLoading else {
                    return .none
                }

                resultState.results[tappedRowIndex].isLoading = true
                state = .results(resultState)

                return .perform { [weatherService] in
                    let weather = try? await weatherService.forecast(
                        latitude: tappedRow.weatherModel.latitude,
                        longitude: tappedRow.weatherModel.longitude
                    )
                    guard let weather else { return nil }
                    return .forecastReceived(index: tappedRowIndex, forecast: weather)
                }

            case .forecastReceived(let index, let forecast):
                guard case .results(var resultState) = state,
                      index < resultState.results.count else {
                    return .none
                }
                resultState.results[index].isLoading = false
                resultState.results[index].forecast = forecast
                state = .results(resultState)
                return .none
            }
        }
        .when(state: \.results, action: \.search) {
            searchQueryInteractor
        }
    }
}

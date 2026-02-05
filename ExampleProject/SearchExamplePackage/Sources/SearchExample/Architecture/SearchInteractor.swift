import Lattice

@Interactor<SearchDomainState, SearchEvent>
struct SearchInteractor: Sendable {
    private let weatherService: WeatherService

    init(weatherService: WeatherService) {
        self.weatherService = weatherService
    }

    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .search:
                return .none

            case .locationTapped(let id):
                guard case .results(var resultState) = state else {
                    return .none
                }

                guard
                    let tappedRowIndex = resultState.results.firstIndex(where: {
                        "\($0.weatherModel.id)" == id
                    })
                else {
                    return .none
                }

                resultState.forecastRequestNonce += 1
                let requestNonce = resultState.forecastRequestNonce

                for index in resultState.results.indices {
                    resultState.results[index].isLoading = false
                }
                resultState.results[tappedRowIndex].isLoading = true
                state = .results(resultState)

                let tappedRow = resultState.results[tappedRowIndex]

                return .perform { [weatherService] in
                    let weather = try? await weatherService.forecast(
                        latitude: tappedRow.weatherModel.latitude,
                        longitude: tappedRow.weatherModel.longitude
                    )
                    guard let weather else { return nil }
                    return .forecastReceived(
                        index: tappedRowIndex,
                        forecast: weather,
                        requestNonce: requestNonce
                    )
                }

            case .forecastReceived(let index, let forecast, let requestNonce):
                guard case .results(var resultState) = state,
                    index < resultState.results.count,
                    requestNonce == resultState.forecastRequestNonce
                else {
                    return .none
                }
                resultState.results[index].isLoading = false
                resultState.results[index].forecast = forecast
                state = .results(resultState)
                return .none
            }
        }
        .when(state: \.results, action: \.search) {
            SearchQueryInteractor<ContinuousClock>(weatherService: weatherService)
        }
    }
}

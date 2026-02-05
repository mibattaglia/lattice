import Lattice

@Interactor<SearchDomainState, SearchEvent>
struct SearchInteractor: Sendable {
    private let weatherService: WeatherService
    private let queryInteractor: AnyInteractor<SearchDomainState.ResultState, SearchQueryEvent>

    init(weatherService: WeatherService) {
        self.init(
            weatherService: weatherService,
            clock: ContinuousClock(),
            debounceDuration: .milliseconds(300)
        )
    }

    init<C: Clock>(
        weatherService: WeatherService,
        clock: C,
        debounceDuration: C.Duration
    ) where C.Duration: Sendable {
        self.weatherService = weatherService
        self.queryInteractor = SearchQueryInteractor<C>(
            weatherService: weatherService,
            clock: clock,
            debounceDuration: debounceDuration
        )
        .eraseToAnyInteractor()
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
            queryInteractor
        }
    }
}

import Lattice

@Interactor<SearchState, SearchEvent>
struct SearchInteractor {
    private let weatherService: WeatherService
    private let queryInteractor: SearchQueryInteractor

    init(
        weatherService: WeatherService,
        clock: any Clock<Duration> = ContinuousClock(),
        debounceDuration: Duration = .milliseconds(300)
    ) {
        self.weatherService = weatherService
        self.queryInteractor = SearchQueryInteractor(
            weatherService: weatherService,
            clock: clock,
            debounceDuration: debounceDuration
        )
    }

    var body: some InteractorOf<Self> {
        Interact { state, event, effects in
            switch event {
            case .search:
                break

            case .locationTapped(let id):
                guard case .results(var resultState) = state,
                    let tappedModel = resultState.results[id: id]?.weatherModel
                else {
                    return
                }

                for itemID in resultState.results.ids {
                    resultState.results[id: itemID]?.isLoading = false
                }
                resultState.results[id: id]?.isLoading = true
                state = .results(resultState)

                // A newer tap replaces this task (same `perform` call site), so a stale forecast
                // can never overwrite a newer request.
                effects.perform { [weatherService] effectState in
                    guard
                        let forecast = try? await weatherService.forecast(
                            latitude: tappedModel.latitude,
                            longitude: tappedModel.longitude
                        )
                    else { return }
                    try effectState.modify { state in
                        guard case .results(var resultState) = state,
                            resultState.results[id: id] != nil
                        else { return }
                        resultState.results[id: id]?.isLoading = false
                        resultState.results[id: id]?.forecast = forecast
                        state = .results(resultState)
                    }
                }
            }
        }
        .when(state: \.results, action: \.search) {
            queryInteractor
        }
    }
}

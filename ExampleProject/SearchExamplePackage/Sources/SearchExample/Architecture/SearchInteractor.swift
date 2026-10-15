import Lattice

@Interactor<SearchState, SearchEvent>
struct SearchInteractor {
    private let weatherService: WeatherService
    private let queryInteractor: AnyInteractor<SearchState.ResultState, SearchQueryEvent>

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
    ) {
        self.weatherService = weatherService
        // Every search the query interactor starts first sleeps for `debounceDuration` on `clock`.
        self.queryInteractor = Interactors.Debounce(for: debounceDuration, clock: clock) {
            SearchQueryInteractor(weatherService: weatherService)
        }
        .eraseToAnyInteractor()
    }

    var body: some InteractorOf<Self> {
        Interact { state, event, effects in
            switch event {
            case .search:
                break

            case .locationTapped(let id):
                guard case .results(var resultState) = state,
                    let tappedRowIndex = resultState.results.firstIndex(where: {
                        "\($0.weatherModel.id)" == id
                    })
                else {
                    return
                }

                for index in resultState.results.indices {
                    resultState.results[index].isLoading = false
                }
                resultState.results[tappedRowIndex].isLoading = true
                state = .results(resultState)

                let location = resultState.results[tappedRowIndex].weatherModel
                // Tapping another row auto-cancels this request: `.locationTapped` is handled
                // again.
                effects.perform {
                    guard
                        let forecast = try? await weatherService.forecast(
                            latitude: location.latitude,
                            longitude: location.longitude
                        )
                    else { return }
                    // Cancelled after the service answered: the forecast is for a row that is no
                    // longer loading. A cancelled effect's modification is still committed, so
                    // check first.
                    try Task.checkCancellation()
                    try effects.modify { state in
                        guard case .results(var resultState) = state,
                            tappedRowIndex < resultState.results.count
                        else {
                            return
                        }
                        resultState.results[tappedRowIndex].isLoading = false
                        resultState.results[tappedRowIndex].forecast = forecast
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

import Lattice

@Interactor<SearchDomainState.ResultState, SearchQueryEvent>
struct SearchQueryInteractor<C: Clock>: Sendable where C.Duration: Sendable {
    private let weatherService: WeatherService
    private let debouncer: Debouncer<C, SearchQueryEvent?>

    init(
        weatherService: WeatherService,
        clock: C,
        debounceDuration: C.Duration
    ) {
        self.weatherService = weatherService
        self.debouncer = Debouncer(for: debounceDuration, clock: clock)
    }

    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .query(let query):
                guard !query.isEmpty else {
                    state = .none
                    return .none
                }
                state.query = query
                return .perform { [weatherService] in
                    do {
                        let weatherModels = try await weatherService.searchWeather(query: query)
                        let weatherResults = weatherModels.results.map { weatherModel in
                            SearchDomainState.ResultState.ResultItem(
                                weatherModel: weatherModel,
                                forecast: nil
                            )
                        }
                        return .searchCompleted(query: query, results: weatherResults)
                    } catch {
                        return .searchFailed
                    }
                }
                .debounce(using: debouncer)

            case .searchCompleted(let query, let results):
                state.results = results
                return .none

            case .searchFailed:
                state.results = []
                return .none
            }
        }
    }
}

extension SearchQueryInteractor where C == ContinuousClock {
    init(weatherService: WeatherService) {
        self.init(
            weatherService: weatherService,
            clock: ContinuousClock(),
            debounceDuration: .milliseconds(300)
        )
    }
}

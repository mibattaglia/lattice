import IdentifiedCollections
import Lattice

@Interactor<SearchState.ResultState, SearchQueryEvent>
struct SearchQueryInteractor {
    let weatherService: WeatherService
    let clock: any Clock<Duration>
    let debounceDuration: Duration

    init(
        weatherService: WeatherService,
        clock: any Clock<Duration> = ContinuousClock(),
        debounceDuration: Duration = .milliseconds(300)
    ) {
        self.weatherService = weatherService
        self.clock = clock
        self.debounceDuration = debounceDuration
    }

    var body: some InteractorOf<Self> {
        Interact { state, event, effects in
            switch event {
            case .query(let query):
                guard !query.isEmpty else {
                    state = .none
                    return
                }
                state.query = query

                // Every `.query` dispatch replaces the previous in-flight task at this
                // `perform` call site: cancelled sleep = restarted debounce window.
                effects.perform { [weatherService, clock, debounceDuration] effectState in
                    try await clock.sleep(for: debounceDuration)
                    do {
                        let weatherModels = try await weatherService.searchWeather(query: query)
                        try effectState.modify { state in
                            state.results = IdentifiedArray(
                                uniqueElements: weatherModels.results.map { weatherModel in
                                    SearchState.ResultState.ResultItem(
                                        weatherModel: weatherModel,
                                        forecast: nil
                                    )
                                }
                            )
                        }
                    } catch {
                        try effectState.modify { state in
                            state.results = []
                        }
                    }
                }
            }
        }
    }
}

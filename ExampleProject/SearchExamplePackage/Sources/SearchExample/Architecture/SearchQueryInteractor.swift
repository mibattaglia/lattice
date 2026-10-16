import Lattice

/// Handles the search field. A query edit updates the field at once and starts a search that first
/// waits out the quiet period on `clock`; the next edit auto-cancels it. Only the last query of a
/// burst reaches the service.
@Interactor<SearchState.ResultState, SearchQueryEvent>
struct SearchQueryInteractor<C: Clock> {
    let weatherService: WeatherService
    let clock: C
    let debounceDuration: C.Duration

    var body: some InteractorOf<Self> {
        Interact { state, event, effects in
            switch event {
            case .query(let query):
                guard !query.isEmpty else {
                    state = .none
                    return
                }
                state.query = query
                effects.perform {
                    try await clock.sleep(for: debounceDuration)  // the next edit auto-cancels this sleep
                    let results: [SearchState.ResultState.ResultItem]
                    do {
                        results = try await weatherService.searchWeather(query: query).results.map {
                            SearchState.ResultState.ResultItem(weatherModel: $0, forecast: nil)
                        }
                    } catch {
                        results = []
                    }
                    // A newer edit cancelled this search while it ran: its results are stale. A
                    // cancelled effect's modification is still committed, so check first.
                    try Task.checkCancellation()
                    try effects.modify { $0.results = results }
                }
            }
        }
    }
}

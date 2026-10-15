import Lattice

/// Handles the search field. A query edit updates the field at once and starts a search; the
/// parent wraps this interactor in `Interactors.Debounce`, so the search first waits out the quiet
/// period, and the next edit auto-cancels it. Only the last query of a burst reaches the service.
@Interactor<SearchState.ResultState, SearchQueryEvent>
struct SearchQueryInteractor {
    let weatherService: WeatherService

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

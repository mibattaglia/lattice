import Foundation
import Lattice

@Interactor<SearchDomainState.ResultState, SearchQueryEvent>
struct SearchQueryInteractor: Sendable {
    private let weatherService: WeatherService
    private let debouncer = Debouncer<ContinuousClock, SearchQueryEvent?>(for: .milliseconds(300))

    init(weatherService: WeatherService) {
        self.weatherService = weatherService
        print("UUID: \(UUID().uuidString)")
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
                    print("searching: \(query)")
                    return .none
                    //                    do {
                    //                        let weatherModels = try await weatherService.searchWeather(query: query)
                    //                        let weatherResults = weatherModels.results.map { weatherModel in
                    //                            SearchDomainState.ResultState.ResultItem(
                    //                                weatherModel: weatherModel,
                    //                                forecast: nil
                    //                            )
                    //                        }
                    //                        return .searchCompleted(query: query, results: weatherResults)
                    //                    } catch {
                    //                        print("Search error: \(error)")
                    //                        return .searchFailed
                    //                    }
                }
                .debounce(using: debouncer)

            case .searchCompleted(let query, let results):
                state.results = results
                return .none

            case .searchFailed:
                return .none
            }
        }
    }
}

import Combine
import CombineSchedulers
import UnoArchitecture

@Interactor<SearchDomainState.ResultState, SearchQueryEvent>
struct SearchQueryInteractor {
    private let weatherService: WeatherService

    init(weatherService: WeatherService) {
        self.weatherService = weatherService
    }

    var body: some InteractorOf<Self> {
        Interact(initialValue: .none) { state, event in
            switch event {
            case let .query(query):
                guard !query.isEmpty else {
                    state = .none
                    return .state
                }
                return .perform { [weatherService] in
                    do {
                        let weatherModels = try await weatherService.searchWeather(query: query)
                        let weatherResults = weatherModels.results.map { weatherModel in
                            SearchDomainState.ResultState.ResultItem(
                                weatherModel: weatherModel,
                                forecast: nil
                            )
                        }
                        return SearchDomainState.ResultState(results: weatherResults)
                    } catch {
                        print("Search error: \(error)")
                        return .none
                    }
                }
            }
        }
    }
}

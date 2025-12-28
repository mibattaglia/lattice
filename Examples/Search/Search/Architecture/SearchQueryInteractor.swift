import Combine
import CombineSchedulers
import UnoArchitecture

//@Interactor<WeatherSearchDomainModel?, SearchQueryEvent>
struct SearchQueryInteractor: Interactor {
    typealias DomainState = WeatherSearchDomainModel?
    typealias Action = SearchQueryEvent

    private let weatherService: WeatherService

    init(weatherService: WeatherService) {
        self.weatherService = weatherService
    }

    var body: some Interactor<DomainState, Action> {
        Interact(initialValue: nil) { state, event in
            switch event {
            case let .query(query):
                guard !query.isEmpty else {
                    state = nil
                    return .state
                }
                return .perform { [weatherService] in
                    do {
                        let result = try await weatherService.searchWeather(query: query)
                        return result
                    } catch {
                        print("Search error: \(error)")
                        return nil
                    }
                }
            }
        }
    }
}

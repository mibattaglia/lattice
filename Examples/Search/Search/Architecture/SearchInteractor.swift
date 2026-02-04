import UnoArchitecture

import Foundation

public final class BodyCacheBox<State: Sendable, Action: Sendable>: @unchecked Sendable {
    private var cached: (any Interactor<State, Action>)?
    private let lock = NSLock()

    public init() {}

    public func getOrBuild<I: Interactor<State, Action>>(@InteractorBuilder<State, Action> build: () -> I) -> I {
        lock.lock()
        defer { lock.unlock() }

        if let cached {
            print("cached value")
            return cached as! I
        }
        let value = build()
        print("building value")
        cached = value
        return value
    }
}

@Interactor<SearchDomainState, SearchEvent>
struct SearchInteractor: Sendable {
    private let weatherService: WeatherService
//    private let searchQueryInteractor: AnyInteractor<SearchDomainState.ResultState, SearchQueryEvent>

    private let _bodyCache = BodyCacheBox<SearchDomainState, SearchEvent>()

    init(weatherService: WeatherService) {
        self.weatherService = weatherService
//        self.searchQueryInteractor = SearchQueryInteractor(weatherService: weatherService)
//            .eraseToAnyInteractor()
    }

    func interact(state: inout SearchDomainState, action: SearchEvent) -> Emission<SearchEvent> {
        _bodyCache.getOrBuild { body }
            .interact(state: &state, action: action)
    }

    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .searchResultsChanged(let results):
                state = .results(results)
                return .none

            case .search:
                return .none

            case .locationTapped(let id):
                guard case .results(var resultState) = state else {
                    return .none
                }

                guard let tappedRowIndex = resultState.results.firstIndex(where: {
                    "\($0.weatherModel.id)" == id
                }) else {
                    return .none
                }

                let tappedRow = resultState.results[tappedRowIndex]

                guard !tappedRow.isLoading else {
                    return .none
                }

                resultState.results[tappedRowIndex].isLoading = true
                state = .results(resultState)

                return .perform { [weatherService] in
                    let weather = try? await weatherService.forecast(
                        latitude: tappedRow.weatherModel.latitude,
                        longitude: tappedRow.weatherModel.longitude
                    )
                    guard let weather else { return nil }
                    return .forecastReceived(index: tappedRowIndex, forecast: weather)
                }

            case .forecastReceived(let index, let forecast):
                guard case .results(var resultState) = state,
                      index < resultState.results.count else {
                    return .none
                }
                resultState.results[index].isLoading = false
                resultState.results[index].forecast = forecast
                state = .results(resultState)
                return .none
            }
        }
        .when(state: \.results, action: \.search) {
//            searchQueryInteractor
            SearchQueryInteractor(weatherService: weatherService)
        }
    }
}

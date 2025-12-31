import Combine
import CombineSchedulers
import Foundation
import UnoArchitecture

@Interactor<SearchDomainState, SearchEvent>
struct SearchInteractor: Sendable {
    private let weatherService: WeatherService

    init(weatherService: WeatherService) {
        self.weatherService = weatherService
    }

    var body: some InteractorOf<Self> {
        Interact(initialValue: .noResults) { state, event in
            switch event {
            case .searchResultsChanged(let results):
                state = .results(results)
                return .state
            case .search:
                return .state
            case let .locationTapped(id):
                let tappedRowIndex = state[dynamicMember: \.results]?.results.firstIndex(where: { "\($0.weatherModel.id)" == id })

                guard let tappedRowIndex,
                      let tappedRow = state[dynamicMember: \.results]?.results[tappedRowIndex] else {
                    return .state
                }
                state.modify(\.results) { domainState in
                    var currentRow = domainState.results[tappedRowIndex]
                    if !currentRow.isLoading {
                        currentRow.isLoading = true
                    }
                }
                return .perform { [weatherService] state, send in
                    var currentState = await state.current
                    let weather = try? await weatherService.forecast(latitude: tappedRow.weatherModel.latitude, longitude: tappedRow.weatherModel.longitude)
                    if let weather {
                        currentState.modify(\.results) { domainState in
                            domainState.results[tappedRowIndex].isLoading = false
                            domainState.results[tappedRowIndex].forecast = weather
                        }
                    }
                    await send(currentState)
                }
            }
        }
        .when(stateIs: \.results, actionIs: \.search, stateAction: \.searchResultsChanged) {
            DebounceInteractor(for: .milliseconds(300)) {
                SearchQueryInteractor(weatherService: weatherService)
            }
        }
    }
}

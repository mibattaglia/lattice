import Clocks
import Foundation
import IdentifiedCollections
import Lattice
import Testing

@testable import SearchExample

private typealias TestClock = Clocks.TestClock<Swift.Duration>

@Suite
@MainActor
struct SearchTests {

    @Test
    func debouncedSearchUsesLatestQuery() async throws {
        let clock = TestClock()
        let weatherService = TestWeatherService()
        weatherService.setSearchResult(
            WeatherSearchDomainModel(results: [makeResult(id: 1, name: "New York")]),
            for: "new"
        )

        let model = makeTestViewModel(
            weatherService: weatherService,
            clock: clock,
            initialState: .results(.none)
        )

        // Update phase: the query lands synchronously; typing again replaces the previous
        // in-flight debounce task at the same perform call site.
        await model.send(.search(.query("n"))) {
            $0 = makeSearchState(query: "n")
        }
        await model.send(.search(.query("ne"))) {
            $0 = makeSearchState(query: "ne")
        }
        await model.send(.search(.query("new"))) {
            $0 = makeSearchState(query: "new")
        }

        #expect(model.domainState == makeSearchState(query: "new"))

        // Cross the debounce window; only the last query's request runs.
        await clock.advance(by: .milliseconds(300))

        await model.expect {
            $0 = makeSearchState(
                query: "new",
                results: [makeResultItem(id: 1, name: "New York")]
            )
        }

        #expect(weatherService.searchCalls() == ["new"])
        await model.dismount()
    }

    @Test
    func tappingNewLocationCancelsOlderForecastRequest() async throws {
        let clock = TestClock()
        let weatherService = TestWeatherService()
        weatherService.forecastDelay = .seconds(1)
        weatherService.forecastClock = clock

        let model = makeTestViewModel(
            weatherService: weatherService,
            clock: clock,
            initialState: makeSearchState(
                query: "",
                results: [
                    makeResultItem(id: 1, name: "First"),
                    makeResultItem(id: 2, name: "Second"),
                ]
            )
        )

        // Tap the first row: its forecast request starts (suspended on the clock).
        await model.send(.locationTapped(id: "1")) { state in
            setLoading(id: "1", in: &state)
        }

        // Tap the second row before the first responds: the same perform call site
        // replaces (cancels) the first request — no nonce bookkeeping needed.
        await model.send(.locationTapped(id: "2")) { state in
            setLoading(id: "2", in: &state)
        }

        await clock.advance(by: .seconds(1))

        // Only the second row's forecast lands; the first request was cancelled at launch
        // of the newer one.
        await model.expect { state in
            applyForecast(makeForecast(dayOffset: 0), id: "2", in: &state)
        }

        #expect(weatherService.forecastCalls() == 2)
        await model.dismount()
    }

    private func makeTestViewModel(
        weatherService: TestWeatherService,
        clock: TestClock,
        initialState: SearchState
    ) -> TestViewModel<SearchState, SearchEvent> {
        TestViewModel(
            initialDomainState: initialState,
            interactor: SearchInteractor(
                weatherService: weatherService,
                clock: clock,
                debounceDuration: .milliseconds(300)
            )
        )
    }
}

// A plain class — nothing in the new runtime requires test doubles to be Sendable.
private final class TestWeatherService: WeatherService {
    private var searchResults: [String: WeatherSearchDomainModel] = [:]
    private var recordedSearchCalls: [String] = []
    private var recordedForecastCalls = 0

    var forecastDelay: Duration = .zero
    var forecastClock: TestClock?

    func setSearchResult(_ model: WeatherSearchDomainModel, for query: String) {
        searchResults[query] = model
    }

    func searchCalls() -> [String] {
        recordedSearchCalls
    }

    func forecastCalls() -> Int {
        recordedForecastCalls
    }

    func searchWeather(query: String) async throws -> WeatherSearchDomainModel {
        recordedSearchCalls.append(query)
        return searchResults[query] ?? WeatherSearchDomainModel(results: [])
    }

    func forecast(latitude: Double, longitude: Double) async throws -> ForecastDomainModel {
        recordedForecastCalls += 1
        if let forecastClock, forecastDelay > .zero {
            try await forecastClock.sleep(for: forecastDelay)
        }
        return makeForecast(dayOffset: 0)
    }
}

private func makeResult(id: Int, name: String) -> WeatherSearchDomainModel.Result {
    WeatherSearchDomainModel.Result(
        country: "US",
        latitude: 40.0,
        longitude: -73.0,
        id: id,
        name: name
    )
}

private func makeSearchState(
    query: String,
    results: [SearchState.ResultState.ResultItem] = []
) -> SearchState {
    .results(
        .init(
            query: query,
            results: IdentifiedArray(uniqueElements: results)
        )
    )
}

private func makeResultItem(
    id: Int,
    name: String,
    forecast: ForecastDomainModel? = nil,
    isLoading: Bool = false
) -> SearchState.ResultState.ResultItem {
    .init(
        weatherModel: makeResult(id: id, name: name),
        forecast: forecast,
        isLoading: isLoading
    )
}

private func setLoading(id: String, in state: inout SearchState) {
    guard case .results(var resultState) = state else { return }
    for itemID in resultState.results.ids {
        resultState.results[id: itemID]?.isLoading = false
    }
    resultState.results[id: id]?.isLoading = true
    state = .results(resultState)
}

private func applyForecast(
    _ forecast: ForecastDomainModel,
    id: String,
    in state: inout SearchState
) {
    guard case .results(var resultState) = state else { return }
    resultState.results[id: id]?.isLoading = false
    resultState.results[id: id]?.forecast = forecast
    state = .results(resultState)
}

private func makeForecast(dayOffset: Int) -> ForecastDomainModel {
    let calendar = Calendar(identifier: .gregorian)
    let baseDate = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
    let date = calendar.date(byAdding: .day, value: dayOffset, to: baseDate) ?? baseDate
    return ForecastDomainModel(
        daily: .init(
            temperatureMax: [20],
            temperatureMin: [10],
            time: [date]
        ),
        dailyUnits: .init(
            temperatureMax: "C",
            temperatureMin: "C"
        )
    )
}

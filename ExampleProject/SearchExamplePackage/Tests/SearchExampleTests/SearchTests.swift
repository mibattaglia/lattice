import Clocks
import Foundation
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
        await weatherService.setSearchResult(
            WeatherSearchDomainModel(results: [makeResult(id: 1, name: "New York")]),
            for: "new"
        )

        let model = makeTestViewModel(
            weatherService: weatherService,
            clock: clock,
            initialDomainState: .results(.none)
        )

        let t1 = try await model.send(.search(.query("n"))) {
            $0 = makeSearchDomainState(query: "n")
        }
        let t2 = try await model.send(.search(.query("ne"))) {
            $0 = makeSearchDomainState(query: "ne")
        }
        let t3 = try await model.send(.search(.query("new"))) {
            $0 = makeSearchDomainState(query: "new")
        }

        #expect(model.domainState == makeSearchDomainState(query: "new"))

        await clock.advance(by: .milliseconds(300))
        try await t1.finish()
        try await t2.finish()
        try await t3.finish()

        let calls = await weatherService.searchCalls()
        #expect(calls == ["new"])

        try await model.receive(
            .search(
                .searchCompleted(
                    query: "new",
                    results: [makeResultItem(id: 1, name: "New York")]
                )
            )
        ) {
            $0 = makeSearchDomainState(
                query: "new",
                results: [makeResultItem(id: 1, name: "New York")]
            )
        }

        #expect(
            model.domainState
                == makeSearchDomainState(
                    query: "new",
                    results: [makeResultItem(id: 1, name: "New York")]
                )
        )
    }

    @Test
    func tappingNewLocationIgnoresOlderForecasts() async throws {
        let clock = TestClock()
        let weatherService = TestWeatherService()

        let model = makeTestViewModel(
            weatherService: weatherService,
            clock: clock,
            initialDomainState: makeSearchDomainState(
                query: "",
                results: [
                    makeResultItem(id: 1, name: "First"),
                    makeResultItem(id: 2, name: "Second"),
                ],
                forecastRequestNonce: 1
            )
        )

        let expectedInitialState = makeSearchDomainState(
            query: "",
            results: [
                makeResultItem(id: 1, name: "First"),
                makeResultItem(id: 2, name: "Second"),
            ],
            forecastRequestNonce: 1
        )

        try await model.send(
            .forecastReceived(
                index: 0,
                forecast: makeForecast(dayOffset: 0),
                requestNonce: 0
            )
        )
        #expect(model.domainState == expectedInitialState)

        try await model.send(
            .forecastReceived(
                index: 1,
                forecast: makeForecast(dayOffset: 1),
                requestNonce: 0
            )
        )
        #expect(model.domainState == expectedInitialState)

        try await model.send(
            .forecastReceived(
                index: 1,
                forecast: makeForecast(dayOffset: 1),
                requestNonce: 1
            )
        ) { state in
            applyForecast(
                makeForecast(dayOffset: 1),
                at: 1,
                in: &state
            )
        }

        #expect(
            model.domainState
                == makeSearchDomainState(
                    query: "",
                    results: [
                        makeResultItem(id: 1, name: "First"),
                        makeResultItem(
                            id: 2,
                            name: "Second",
                            forecast: makeForecast(dayOffset: 1)
                        ),
                    ],
                    forecastRequestNonce: 1
                )
        )
    }

    private func makeTestViewModel(
        weatherService: TestWeatherService,
        clock: TestClock,
        initialDomainState: SearchDomainState
    ) -> TestViewModel<Feature<SearchEvent, SearchDomainState, SearchViewState>> {
        TestViewModel(
            initialDomainState: initialDomainState,
            feature: Feature(
                interactor: SearchInteractor(
                    weatherService: weatherService,
                    clock: clock,
                    debounceDuration: .milliseconds(300)
                ),
                reducer: SearchViewStateReducer()
            )
        )
    }
}

private actor TestWeatherService: WeatherService {
    private var searchResults: [String: WeatherSearchDomainModel] = [:]
    private var recordedSearchCalls: [String] = []
    private var forecastResults: [ForecastKey: ForecastDomainModel] = [:]

    func setSearchResult(_ model: WeatherSearchDomainModel, for query: String) {
        searchResults[query] = model
    }

    func searchCalls() -> [String] {
        recordedSearchCalls
    }

    func searchWeather(query: String) async throws -> WeatherSearchDomainModel {
        recordedSearchCalls.append(query)
        return searchResults[query] ?? WeatherSearchDomainModel(results: [])
    }

    func forecast(latitude: Double, longitude: Double) async throws -> ForecastDomainModel {
        return forecastResults[ForecastKey(latitude: latitude, longitude: longitude)]
            ?? ForecastDomainModel(
                daily: .init(temperatureMax: [], temperatureMin: [], time: []),
                dailyUnits: .init(temperatureMax: "", temperatureMin: "")
            )
    }

    func setForecast(_ model: ForecastDomainModel, for location: (latitude: Double, longitude: Double)) {
        forecastResults[ForecastKey(latitude: location.latitude, longitude: location.longitude)] = model
    }
}

private struct ForecastKey: Hashable {
    let latitude: Double
    let longitude: Double
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

private func makeSearchDomainState(
    query: String,
    results: [SearchDomainState.ResultState.ResultItem] = [],
    forecastRequestNonce: Int = 0
) -> SearchDomainState {
    .results(
        .init(
            query: query,
            results: results,
            forecastRequestNonce: forecastRequestNonce
        )
    )
}

private func makeResultItem(
    id: Int,
    name: String,
    forecast: ForecastDomainModel? = nil,
    isLoading: Bool = false
) -> SearchDomainState.ResultState.ResultItem {
    .init(
        isLoading: isLoading,
        weatherModel: makeResult(id: id, name: name),
        forecast: forecast
    )
}

private func applyForecast(
    _ forecast: ForecastDomainModel,
    at index: Int,
    in state: inout SearchDomainState
) {
    guard case .results(var resultState) = state, index < resultState.results.count else {
        return
    }

    resultState.results[index].isLoading = false
    resultState.results[index].forecast = forecast
    state = .results(resultState)
}

private func makeForecast(dayOffset: Int) -> ForecastDomainModel {
    let calendar = Calendar(identifier: .gregorian)
    let baseDate = calendar.startOfDay(for: Date())
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

import Clocks
import Foundation
import Lattice
import Observation
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
            initialState: .results(.none)
        )

        let t1 = try await model.send(.search(.query("n"))) {
            $0 = makeSearchState(query: "n")
        }
        let t2 = try await model.send(.search(.query("ne"))) {
            $0 = makeSearchState(query: "ne")
        }
        let t3 = try await model.send(.search(.query("new"))) {
            $0 = makeSearchState(query: "new")
        }

        #expect(model.state == makeSearchState(query: "new"))

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
            $0 = makeSearchState(
                query: "new",
                results: [makeResultItem(id: 1, name: "New York")]
            )
        }

        #expect(
            model.state
                == makeSearchState(
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
            initialState: makeSearchState(
                query: "",
                results: [
                    makeResultItem(id: 1, name: "First"),
                    makeResultItem(id: 2, name: "Second"),
                ],
                forecastRequestNonce: 1
            )
        )

        let expectedInitialState = makeSearchState(
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
        #expect(model.state == expectedInitialState)

        try await model.send(
            .forecastReceived(
                index: 1,
                forecast: makeForecast(dayOffset: 1),
                requestNonce: 0
            )
        )
        #expect(model.state == expectedInitialState)

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
            model.state
                == makeSearchState(
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

    // `.results` carries a `@FeatureState` payload, so typing a query invalidates only the
    // query readers: the `switch viewModel.viewState` and the list it shows stay put.
    @Test
    func queryEditInvalidatesOnlyTheQueryReaders() {
        let viewModel = ViewModel(
            initialState: .results(.none),
            feature: Feature(
                interactor: SearchInteractor(
                    weatherService: TestWeatherService(),
                    clock: TestClock(),
                    debounceDuration: .milliseconds(300)
                )
            )
        )
        let query = ChangeProbe()
        let caseSwitch = ChangeProbe()
        let listItems = ChangeProbe()
        withObservationTracking { _ = viewModel.viewState[case: \.results]?.query } onChange: { query.didChange = true }
        withObservationTracking { _ = viewModel.viewState } onChange: { caseSwitch.didChange = true }
        withObservationTracking { _ = viewModel.viewState[case: \.results]?.listItems } onChange: {
            listItems.didChange = true
        }

        viewModel.sendViewEvent(.search(.query("new")))
        #expect(query.didChange)
        #expect(!caseSwitch.didChange)
        #expect(!listItems.didChange)
        #expect(viewModel.viewState[case: \.results]?.query == "new")
    }

    private func makeTestViewModel(
        weatherService: TestWeatherService,
        clock: TestClock,
        initialState: SearchState
    ) -> TestViewModel<Feature<SearchEvent, SearchState>> {
        TestViewModel(
            initialState: initialState,
            feature: Feature(
                interactor: SearchInteractor(
                    weatherService: weatherService,
                    clock: clock,
                    debounceDuration: .milliseconds(300)
                )
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

private final class ChangeProbe: @unchecked Sendable {
    var didChange = false
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

private func makeSearchState(
    query: String,
    results: [SearchState.ResultState.ResultItem] = [],
    forecastRequestNonce: Int = 0
) -> SearchState {
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
) -> SearchState.ResultState.ResultItem {
    .init(
        isLoading: isLoading,
        weatherModel: makeResult(id: id, name: name),
        forecast: forecast
    )
}

private func applyForecast(
    _ forecast: ForecastDomainModel,
    at index: Int,
    in state: inout SearchState
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

import Foundation
import Lattice
import Observation
import Testing

@testable import SearchExample

// The feature runs under `TestModel`, so the suite is not `@MainActor` and every test that creates
// one is `@available(macOS 26, *)` (the package supports macOS 14). Time is a `GateClock`: a test
// waits until the debounced search is sleeping, then moves the clock past the quiet period.

@Suite
struct SearchTests {
    /// Each edit auto-cancels the search the previous edit started while that search was still
    /// waiting out the debounce, so only the last query reaches the service.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func debouncedSearchUsesLatestQuery() async {
        let clock = GateClock()
        let searches = CallLog()
        let model = await makeModel(
            initialState: .results(.none),
            weatherService: StubWeatherService(
                searchResults: ["new": WeatherSearchDomainModel(results: [makeResult(id: 1, name: "New York")])],
                searches: searches
            ),
            clock: clock
        )

        await model.send(.search(.query("n"))) { $0 = makeSearchState(query: "n") }
        await model.send(.search(.query("ne"))) { $0 = makeSearchState(query: "ne") }
        let search = await model.send(.search(.query("new"))) { $0 = makeSearchState(query: "new") }

        await clock.waitForSleepers(1)  // only the "new" search is still waiting
        clock.moveForward(by: .milliseconds(300))
        await search?.value

        #expect(searches.entries == ["new"])
        await model.expect {  // the search wrote its results directly
            $0 = makeSearchState(query: "new", results: [makeResultItem(id: 1, name: "New York")])
        }
        await model.finish()
    }

    /// Clearing the field auto-cancels the search that is still waiting out the debounce.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func clearingTheQueryCancelsTheWaitingSearch() async {
        let clock = GateClock()
        let searches = CallLog()
        let model = await makeModel(
            initialState: .results(.none),
            weatherService: StubWeatherService(searches: searches),
            clock: clock
        )

        await model.send(.search(.query("new"))) { $0 = makeSearchState(query: "new") }
        await clock.waitForSleepers(1)
        await model.send(.search(.query(""))) { $0 = makeSearchState(query: "") }

        #expect(clock.pendingSleeps == [])
        await model.finish()
        #expect(searches.entries == [])
    }

    /// An edit while a search waits for the service auto-cancels that search, so its answer, which
    /// arrives afterwards, is dropped: only the last query's results are shown.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func editingDuringASearchDropsItsResults() async {
        let clock = GateClock()
        let answers = Gate()
        let searches = CallLog()
        let model = await makeModel(
            initialState: .results(.none),
            weatherService: StubWeatherService(
                searchResults: [
                    "ne": WeatherSearchDomainModel(results: [makeResult(id: 1, name: "Nebraska")]),
                    "new": WeatherSearchDomainModel(results: [makeResult(id: 2, name: "New York")]),
                ],
                searches: searches,
                searchGate: answers
            ),
            clock: clock
        )

        let staleSearch = await model.send(.search(.query("ne"))) { $0 = makeSearchState(query: "ne") }
        await clock.waitForSleepers(1)
        clock.moveForward(by: .milliseconds(300))  // the "ne" search wakes and calls the service
        await answers.waitForWaiters(1)  // it is waiting for its answer
        #expect(searches.entries == ["ne"])
        let search = await model.send(.search(.query("new"))) { $0 = makeSearchState(query: "new") }
        answers.open()  // the "ne" answer arrives after the edit cancelled its search
        await staleSearch?.value
        await model.expect { _ in }  // nothing was written

        await clock.waitForSleepers(1)
        clock.moveForward(by: .milliseconds(300))
        await search?.value

        #expect(searches.entries == ["ne", "new"])
        await model.expect {
            $0 = makeSearchState(query: "new", results: [makeResultItem(id: 2, name: "New York")])
        }
        await model.finish()
    }

    /// Tapping a row loads its forecast. Tapping another row auto-cancels that request, so the
    /// answer it gets afterwards is dropped: only the second row shows a forecast.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func tappingAnotherLocationDropsTheEarlierForecast() async {
        let forecasts = Gate()
        let first = makeResultItem(id: 1, name: "First")
        let second = makeResultItem(id: 2, name: "Second")
        let firstForecast = makeForecast(dayOffset: 0)
        let secondForecast = makeForecast(dayOffset: 1)
        let model = await makeModel(
            initialState: makeSearchState(query: "", results: [first, second]),
            weatherService: StubWeatherService(
                forecasts: [
                    first.weatherModel.latitude: firstForecast,
                    second.weatherModel.latitude: secondForecast,
                ],
                forecastGate: forecasts
            )
        )

        let firstRequest = await model.send(.locationTapped(id: "1")) {
            $0 = makeSearchState(query: "", results: [makeResultItem(id: 1, name: "First", isLoading: true), second])
        }
        let secondRequest = await model.send(.locationTapped(id: "2")) {
            $0 = makeSearchState(query: "", results: [first, makeResultItem(id: 2, name: "Second", isLoading: true)])
        }
        forecasts.open()  // both requests get their answer; the first one is stale
        await firstRequest?.value
        await secondRequest?.value

        await model.expect {
            $0 = makeSearchState(
                query: "",
                results: [first, makeResultItem(id: 2, name: "Second", forecast: secondForecast)]
            )
        }
        await model.finish()
    }

    // `.results` carries a `@FeatureState` payload, so typing a query invalidates only the
    // query readers: the `switch viewModel.viewState` and the list it shows stay put.
    @MainActor
    @Test
    func queryEditInvalidatesOnlyTheQueryReaders() {
        let viewModel = ViewModel(
            initialState: .results(.none),
            feature: Feature(
                interactor: SearchInteractor(
                    weatherService: StubWeatherService(),
                    clock: GateClock(),
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
}

/// A test model over the search feature. The stub is handed over to the model (`sending`): it is not
/// `Sendable`, and the test keeps only the log and gate it shares with it.
@available(macOS 26, *)
private func makeModel(
    initialState: SearchState,
    weatherService: sending StubWeatherService,
    clock: GateClock = GateClock()
) async -> TestModel<Feature<SearchEvent, SearchState>> {
    await TestModel(
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

private final class ChangeProbe: @unchecked Sendable {
    var didChange = false
}

private func makeResult(id: Int, name: String) -> WeatherSearchDomainModel.Result {
    WeatherSearchDomainModel.Result(
        country: "US",
        latitude: Double(id),
        longitude: -73.0,
        id: id,
        name: name
    )
}

private func makeSearchState(
    query: String,
    results: [SearchState.ResultState.ResultItem] = []
) -> SearchState {
    .results(.init(query: query, results: results))
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

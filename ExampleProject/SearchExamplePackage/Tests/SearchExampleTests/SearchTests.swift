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

        let viewModel = ViewModel(
            initialDomainState: .results(.none),
            initialViewState: .loaded(SearchListContent(query: "", listItems: [])),
            interactor: SearchInteractor(
                weatherService: weatherService,
                clock: clock,
                debounceDuration: .milliseconds(300)
            )
            .eraseToAnyInteractor(),
            viewStateReducer: SearchViewStateReducer().eraseToAnyReducer()
        )

        let t1 = viewModel.sendViewEvent(.search(.query("n")))
        let t2 = viewModel.sendViewEvent(.search(.query("ne")))
        let t3 = viewModel.sendViewEvent(.search(.query("new")))

        await clock.advance(by: .milliseconds(300))
        await t1.finish()
        await t2.finish()
        await t3.finish()

        let calls = await weatherService.searchCalls()
        #expect(calls == ["new"])

        guard case .loaded(let content) = viewModel.viewState else {
            Issue.record("Expected loaded view state")
            return
        }

        #expect(content.query == "new")
        #expect(content.listItems.count == 1)
        #expect(content.listItems.first?.name == "New York")
    }

    @Test
    func tappingNewLocationIgnoresOlderForecasts() async throws {
        let weatherService = TestWeatherService()
        let first = makeResult(id: 1, name: "First")
        let second = makeResult(id: 2, name: "Second")

        let viewModel = ViewModel(
            initialDomainState: .results(
                .init(
                    query: "",
                    results: [
                        .init(weatherModel: first, forecast: nil),
                        .init(weatherModel: second, forecast: nil),
                    ],
                    forecastRequestNonce: 1
                )
            ),
            initialViewState: .loaded(SearchListContent(query: "", listItems: [])),
            interactor: SearchInteractor(weatherService: weatherService).eraseToAnyInteractor(),
            viewStateReducer: SearchViewStateReducer().eraseToAnyReducer()
        )

        viewModel.sendViewEvent(.forecastReceived(index: 0, forecast: makeForecast(dayOffset: 0), requestNonce: 0))
        viewModel.sendViewEvent(.forecastReceived(index: 1, forecast: makeForecast(dayOffset: 1), requestNonce: 0))
        viewModel.sendViewEvent(.forecastReceived(index: 1, forecast: makeForecast(dayOffset: 1), requestNonce: 1))

        guard case .loaded(let content) = viewModel.viewState else {
            Issue.record("Expected loaded view state")
            return
        }

        #expect(content.listItems.count == 2)
        let firstItem = content.listItems[0]
        let secondItem = content.listItems[1]

        #expect(firstItem.weather == nil)
        #expect(secondItem.weather != nil)
        #expect(firstItem.isLoading == false)
        #expect(secondItem.isLoading == false)
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

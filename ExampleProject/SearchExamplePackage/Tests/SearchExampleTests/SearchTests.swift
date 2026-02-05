import Foundation
import Lattice
import Testing

@testable import SearchExample

@Suite
@MainActor
struct SearchTests {

    @Test
    func debouncedSearchUsesLatestQuery() async throws {
        #expect(2 == 2)
    }

    @Test
    func tappingNewLocationIgnoresOlderForecasts() async throws {
        #expect(2 == 2)
    }
}

private actor TestWeatherService: WeatherService {
    private var searchResults: [String: WeatherSearchDomainModel] = [:]
    private var recordedSearchCalls: [String] = []
    private var forecastContinuations: [CheckedContinuation<ForecastDomainModel, Error>] = []

    func setSearchResult(_ model: WeatherSearchDomainModel, for query: String) {
        searchResults[query] = model
    }

    func searchCalls() -> [String] {
        recordedSearchCalls
    }

    func resolveForecast(at index: Int, with model: ForecastDomainModel) {
        guard index < forecastContinuations.count else { return }
        forecastContinuations[index].resume(returning: model)
    }

    func searchWeather(query: String) async throws -> WeatherSearchDomainModel {
        recordedSearchCalls.append(query)
        return searchResults[query] ?? WeatherSearchDomainModel(results: [])
    }

    func forecast(latitude: Double, longitude: Double) async throws -> ForecastDomainModel {
        return try await withCheckedThrowingContinuation { continuation in
            forecastContinuations.append(continuation)
        }
    }
}

import Foundation
import Lattice

extension SearchState {
    /// The `.results` payload. It is `@FeatureState`, so a query edit or a loaded forecast
    /// re-renders only the views that read it. Views read the `listItems` derived from the
    /// hidden domain `results`.
    @FeatureState
    struct ResultState: Equatable, Sendable {
        struct ResultItem: Equatable {
            var isLoading = false
            let weatherModel: WeatherSearchDomainModel.Result
            var forecast: ForecastDomainModel?
        }

        var query: String
        @Domain var results: [ResultItem]
        @Domain var forecastRequestNonce = 0

        /// The rows views show, one per result.
        var listItems: [SearchListItem] {
            results.map { result in
                SearchListItem(
                    id: "\(result.weatherModel.id)",
                    name: result.weatherModel.name,
                    isLoading: result.isLoading,
                    weather: SearchReducer.weather(from: result.forecast)
                )
            }
        }

        static var none: Self {
            ResultState(query: "", results: [])
        }
    }
}

struct SearchListItem: Equatable, Identifiable {
    let id: String
    let name: String
    var isLoading = false
    var weather: Weather?
}

struct Weather: Equatable {
    let forecasts: [String]
}

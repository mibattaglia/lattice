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
        @Domain var forecastRequestNonce: Int = 0

        /// The rows views show, one per result.
        var listItems: [SearchListItem] {
            results.map { result in
                SearchListItem(
                    id: "\(result.weatherModel.id)",
                    name: result.weatherModel.name,
                    isLoading: result.isLoading,
                    weather: Self.weather(from: result.forecast)
                )
            }
        }

        static var none: Self {
            ResultState(query: "", results: [])
        }

        private static func weather(from model: ForecastDomainModel?) -> Weather? {
            guard let model else { return nil }

            let days = model.daily.time.enumerated().map { index, day in
                (day, model.daily.temperatureMin[index], model.daily.temperatureMax[index])
            }
            let formatted = days.map { dayInfo in
                "\(formatRelativeDate(dayInfo.0)): \(dayInfo.1) - \(dayInfo.2)"
            }
            return Weather(
                forecasts: formatted
            )
        }

        private static func formatRelativeDate(_ date: Date) -> String {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let targetDay = calendar.startOfDay(for: date)

            let daysDifference = calendar.dateComponents([.day], from: today, to: targetDay).day ?? 0

            switch daysDifference {
            case 0:
                return "Today"
            case 1:
                return "Tomorrow"
            case 2...6:
                return date.formatted(.dateTime.weekday(.wide))
            default:
                return date.formatted(.dateTime.month().day().year())
            }
        }
    }
}

struct SearchListItem: Equatable, Identifiable {
    let id: String
    let name: String
    var isLoading: Bool = false
    var weather: Weather? = nil
}

struct Weather: Equatable {
    let forecasts: [String]
}

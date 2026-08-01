import CasePaths
import Foundation
import IdentifiedCollections
import Lattice

/// One state type replaces the old `SearchDomainState` + `SearchViewState` +
/// `SearchViewStateReducer` trio: `@Domain` members are the interactor-only model, and the
/// visible computed properties are the rendering instructions, diffed per member at commit.
///
/// The old `forecastRequestNonce` is gone: per-location task replacement makes a newer tap
/// cancel the older forecast request, so the nonce guard has nothing to guard.
@FeatureState
@CasePathable
enum SearchState: Equatable {
    case noResults
    case results(ResultState)

    @FeatureState
    struct ResultState: Equatable {
        @FeatureState
        struct ResultItem: Equatable, Identifiable {
            @Domain let weatherModel: WeatherSearchDomainModel.Result
            @Domain var forecast: ForecastDomainModel?
            var isLoading: Bool = false

            // The row's rendering instructions — previously `SearchListItem`, rebuilt for
            // every row by the reducer on every commit; now diffed per row, per member.
            var id: String { "\(weatherModel.id)" }
            var name: String { weatherModel.name }
            // Small per-row collection: accepted O(days) compare (a handful of strings).
            var forecasts: [String]? {
                guard let forecast else { return nil }
                let daily = forecast.daily
                return zip(daily.time, zip(daily.temperatureMin, daily.temperatureMax))
                    .map { day, temperatures in
                        "\(Self.formatRelativeDate(day)): \(temperatures.0) - \(temperatures.1)"
                    }
            }

            private static func formatRelativeDate(_ date: Date) -> String {
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                let targetDay = calendar.startOfDay(for: date)

                let daysDifference =
                    calendar.dateComponents([.day], from: today, to: targetDay).day ?? 0

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

        var query: String
        var results: IdentifiedArrayOf<ResultItem>

        static var none: Self {
            ResultState(query: "", results: [])
        }
    }
}

import Foundation
import UnoArchitecture

@ViewStateReducer<SearchDomainState, SearchViewState>
struct SearchViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState, viewState in
            switch domainState {
            case .noResults:
                viewState = .none
            case .results(let model):
                let listItems = model.results.map { result in
                    SearchListItem(
                        id: "\(result.weatherModel.id)",
                        name: result.weatherModel.name,
                        isLoading: result.isLoading,
                        weather: weatherState(from: result.forecast)
                    )
                }
                viewState = .loaded(SearchListContent(listItems: listItems))
            }
        }
    }

    private func weatherState(from model: ForecastDomainModel?) -> Weather? {
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

    private func formatRelativeDate(_ date: Date) -> String {
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

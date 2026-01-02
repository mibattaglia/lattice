import Foundation
import UnoArchitecture

@ObservableState
enum SearchViewState: Equatable {
    case none
    case loaded(SearchListContent)
}

struct SearchListContent: Equatable {
    let listItems: [SearchListItem]
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

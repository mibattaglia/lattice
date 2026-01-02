import Foundation
import UnoArchitecture
<<<<<<< Updated upstream

@ObservableState
=======
import CasePaths

@CasePathable
>>>>>>> Stashed changes
enum SearchViewState: Equatable {
    case none
    case loaded(SearchListContent)
}

@ObservableState
struct SearchListContent: Equatable {
    var listItems: [SearchListItem]
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

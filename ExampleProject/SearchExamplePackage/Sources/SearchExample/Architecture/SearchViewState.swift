import CasePaths
import Foundation
import Lattice

/// NB: this being an enum is probably overkill, but I wanted to show off the
/// power of observing enums and binding to enums in this demo.
@CasePathable
@ObservableState
@dynamicMemberLookup
enum SearchViewState: Equatable {
    case none
    case loaded(SearchListContent)
}

struct SearchListContent: Equatable {
    var query: String
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

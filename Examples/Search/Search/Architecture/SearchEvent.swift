import CasePaths

@CasePathable
enum SearchEvent: Equatable {
    case search(SearchQueryEvent)
    case searchResultsChanged(WeatherSearchDomainModel?)
    case locationTapped(id: String)
}

@CasePathable
enum SearchQueryEvent: Equatable, Sendable {
    case query(String)
}

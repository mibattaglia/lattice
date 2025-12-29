import CasePaths

@CasePathable
enum SearchEvent: Equatable {
    case search(SearchQueryEvent)
    case searchResultsChanged(SearchDomainState.ResultState)
    case locationTapped(id: String)
}

@CasePathable
enum SearchQueryEvent: Equatable, Sendable {
    case query(String)
}

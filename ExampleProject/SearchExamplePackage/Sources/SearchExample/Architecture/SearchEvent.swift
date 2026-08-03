import CasePaths

@CasePathable
enum SearchEvent: Equatable {
    case search(SearchQueryEvent)
    case locationTapped(id: String)
}

@CasePathable
enum SearchQueryEvent: Equatable {
    case query(String)
}

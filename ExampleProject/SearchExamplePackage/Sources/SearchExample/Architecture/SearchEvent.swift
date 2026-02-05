import CasePaths

@CasePathable
enum SearchEvent: Equatable, Sendable {
    case search(SearchQueryEvent)
    case locationTapped(id: String)
    case forecastReceived(index: Int, forecast: ForecastDomainModel, requestNonce: Int)
}

@CasePathable
enum SearchQueryEvent: Equatable, Sendable {
    case query(String)
    case searchCompleted(query: String, results: [SearchDomainState.ResultState.ResultItem])
    case searchFailed
}

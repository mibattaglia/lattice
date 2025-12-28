import CasePaths

@CasePathable
enum SearchDomainState: Equatable {
    case none
    case results(WeatherSearchDomainModel?)
}

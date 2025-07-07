import CasePaths

@CasePathable
enum SearchDomainState {
    case none
    case loaded(Content)

    struct Content: Equatable {
        var model: WeatherSearchDomainModel
    }
}

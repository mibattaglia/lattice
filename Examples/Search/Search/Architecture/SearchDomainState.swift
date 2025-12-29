import CasePaths

@CasePathable
enum SearchDomainState: Equatable {
    case noResults
    case results(ResultState)

    struct ResultState: Equatable {
        struct ResultItem: Equatable {
            var isLoading = false
            let weatherModel: WeatherSearchDomainModel.Result
            var forecast: ForecastDomainModel?
        }

        var results: [ResultItem]

        static var none: Self {
            ResultState(results: [])
        }
    }
}

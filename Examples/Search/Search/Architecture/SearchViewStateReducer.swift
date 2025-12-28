import Foundation
import UnoArchitecture

@ViewStateReducer<SearchDomainState, SearchViewState>
struct SearchViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState in
            switch domainState {
            case .none:
                return .none
            case .results(let model):
                guard let model else {
                    return .none
                }
                let listItems = model.results.map { result in
                    SearchListItem(id: "\(result.id)", name: result.name)
                }
                return .loaded(SearchListContent(listItems: listItems))
            }
        }
    }
}

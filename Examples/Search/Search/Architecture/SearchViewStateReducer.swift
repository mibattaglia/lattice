import Foundation
import UnoArchitecture

@ViewStateReducer<SearchDomainState, SearchViewState>
struct SearchViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState in
            return .none
        }
    }
}

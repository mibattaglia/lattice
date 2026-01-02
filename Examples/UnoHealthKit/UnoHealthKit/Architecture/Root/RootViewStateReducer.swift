import Foundation
import UnoArchitecture

@ViewStateReducer<RootDomainState, RootViewState>
struct RootViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState, viewState in
            switch domainState {
            case .checkingPermission:
                viewState = .loading
            case .needsPermission:
                viewState = .permissionRequired
            case .requestingPermission:
                viewState = .requestingPermission
            case .permissionDenied:
                viewState = .permissionDenied
            case .authorized:
                viewState = .ready
            }
        }
    }
}

import Foundation
import UnoArchitecture

@ViewStateReducer<RootDomainState, RootViewState>
struct RootViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState in
            switch domainState {
            case .checkingPermission:
                return .loading
            case .needsPermission:
                return .permissionRequired
            case .requestingPermission:
                return .requestingPermission
            case .permissionDenied:
                return .permissionDenied
            case .authorized:
                return .ready
            }
        }
    }
}

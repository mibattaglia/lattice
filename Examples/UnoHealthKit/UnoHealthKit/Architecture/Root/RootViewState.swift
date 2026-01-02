import Foundation
import UnoArchitecture

@ObservableState
enum RootViewState: Equatable {
    case loading
    case permissionRequired
    case requestingPermission
    case permissionDenied
    case ready
}

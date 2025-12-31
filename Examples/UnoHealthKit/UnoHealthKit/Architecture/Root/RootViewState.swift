import Foundation

enum RootViewState: Equatable {
    case loading
    case permissionRequired
    case requestingPermission
    case permissionDenied
    case ready
}

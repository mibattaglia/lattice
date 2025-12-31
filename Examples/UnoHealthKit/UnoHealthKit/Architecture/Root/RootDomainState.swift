import CasePaths

@CasePathable
enum RootDomainState: Equatable {
    case checkingPermission
    case needsPermission
    case requestingPermission
    case permissionDenied
    case authorized
}

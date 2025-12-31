import CasePaths

@CasePathable
enum RootEvent: Equatable, Sendable {
    case onAppear
    case requestPermission
    case permissionResult(granted: Bool)
}

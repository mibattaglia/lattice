import CasePaths

@CasePathable
enum TrendsEvent: Equatable, Sendable {
    case onAppear
    case refresh
}

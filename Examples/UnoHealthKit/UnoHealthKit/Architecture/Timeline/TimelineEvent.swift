import CasePaths

@CasePathable
enum TimelineEvent: Equatable, Sendable {
    case onAppear
    case errorOccurred(String)
}

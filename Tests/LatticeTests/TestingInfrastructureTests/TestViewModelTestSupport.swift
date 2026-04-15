import Observation
import Testing

@testable import Lattice

@ObservableState
struct TestSupportViewState: Equatable, Sendable {}

typealias TestSupportFeature<Action, DomainState> = Feature<Action, DomainState, TestSupportViewState>

@MainActor
func makeTestViewModel<I: Interactor & Sendable>(
    initialDomainState: I.DomainState,
    interactor: I
) -> TestViewModel<TestSupportFeature<I.Action, I.DomainState>>
where I.DomainState: Equatable {
    TestViewModel<TestSupportFeature<I.Action, I.DomainState>>(
        initialDomainState: initialDomainState,
        interactor: interactor.eraseToAnyInteractor(),
        areStatesEqual: { $0 == $1 }
    )
}

@MainActor
func expectTestFailure(
    containing expectedMessage: String,
    _ operation: @escaping @MainActor () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected TestFailure containing: \(expectedMessage)")
    } catch {
        #expect(String(describing: error).contains(expectedMessage))
    }
}

import Foundation
import Testing

@testable import Lattice

@Suite
@MainActor
final class AsyncCounterInteractorTests {

    @Test func asyncWork() async throws {
        let model = makeTestViewModel(
            initialDomainState: AsyncCounterInteractor.State(count: 0),
            interactor: AsyncCounterInteractor()
        )

        _ = try await model.send(.increment) {
            $0.count = 1
        }

        let task = try await model.send(.asyncIncrement) { _ in }
        try await task.finish()

        try await model.receive(.increment) {
            $0.count = 2
        }

        _ = try await model.send(.increment) {
            $0.count = 3
        }

        #expect(model.domainState == .init(count: 3))
    }
}

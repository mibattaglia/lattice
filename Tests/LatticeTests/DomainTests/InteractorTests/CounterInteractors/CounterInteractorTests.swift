import Foundation
import Testing

@testable import Lattice

@Suite
@MainActor
final class CounterInteractorTests {

    @Test
    func increment() async throws {
        let model = makeModel()

        _ = try await model.send(.increment) { $0.count = 1 }
        _ = try await model.send(.increment) { $0.count = 2 }
        _ = try await model.send(.increment) { $0.count = 3 }

        #expect(model.domainState == .init(count: 3))
    }

    @Test
    func decrement() async throws {
        let model = makeModel()

        _ = try await model.send(.increment) { $0.count = 1 }
        _ = try await model.send(.increment) { $0.count = 2 }
        _ = try await model.send(.increment) { $0.count = 3 }
        _ = try await model.send(.decrement) { $0.count = 2 }
        _ = try await model.send(.decrement) { $0.count = 1 }
        _ = try await model.send(.decrement) { $0.count = 0 }

        #expect(model.domainState == .init(count: 0))
    }

    @Test
    func reset() async throws {
        let model = makeModel()

        _ = try await model.send(.increment) { $0.count = 1 }
        _ = try await model.send(.increment) { $0.count = 2 }
        _ = try await model.send(.increment) { $0.count = 3 }
        _ = try await model.send(.reset) { $0.count = 0 }

        #expect(model.domainState == .init(count: 0))
    }

    private func makeModel()
        -> TestViewModel<TestSupportFeature<CounterInteractor.Action, CounterInteractor.State>>
    {
        makeTestViewModel(
            initialDomainState: CounterInteractor.State(count: 0),
            interactor: CounterInteractor()
        )
    }
}

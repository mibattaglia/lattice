import Foundation
import Testing

@testable import Lattice

@Suite
@MainActor
final class CounterInteractorTests {

    @Test
    func increment() async {
        let model = makeModel()

        _ = await model.send(.increment) { $0.count = 1 }
        _ = await model.send(.increment) { $0.count = 2 }
        _ = await model.send(.increment) { $0.count = 3 }

        #expect(model.domainState == .init(count: 3))
    }

    @Test
    func decrement() async {
        let model = makeModel()

        _ = await model.send(.increment) { $0.count = 1 }
        _ = await model.send(.increment) { $0.count = 2 }
        _ = await model.send(.increment) { $0.count = 3 }
        _ = await model.send(.decrement) { $0.count = 2 }
        _ = await model.send(.decrement) { $0.count = 1 }
        _ = await model.send(.decrement) { $0.count = 0 }

        #expect(model.domainState == .init(count: 0))
    }

    @Test
    func reset() async {
        let model = makeModel()

        _ = await model.send(.increment) { $0.count = 1 }
        _ = await model.send(.increment) { $0.count = 2 }
        _ = await model.send(.increment) { $0.count = 3 }
        _ = await model.send(.reset) { $0.count = 0 }

        #expect(model.domainState == .init(count: 0))
    }

    private func makeModel()
        -> TestViewModel<TestSupportFeature<CounterAction, CounterState>>
    {
        makeTestViewModel(
            initialDomainState: CounterState(count: 0),
            interactor: CounterInteractor()
        )
    }
}

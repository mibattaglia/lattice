@preconcurrency import Combine
import Foundation
import Testing

@testable import Lattice

@Suite
struct HotCounterInteractorTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func asyncWork() async {
        let model = await TestModel(
            initialState: HotCounterInteractor.State(count: 0),
            feature: Feature(interactor: HotCounterInteractor())
        )

        await model.send(.increment) { $0.count = 1 }

        // The effect sends `.addValue` for every value the publisher emits, until it finishes.
        let intPublisher = CurrentValueSubject<Int, Never>(1)
        let observeTask = await model.send(.observe(intPublisher.eraseToAnyPublisher()))

        await model.receive({
            if case .addValue(1) = $0 { return true }
            return false
        }) {
            $0.count = 2
        }

        intPublisher.send(2)
        await model.receive({
            if case .addValue(2) = $0 { return true }
            return false
        }) {
            $0.count = 4
        }

        await model.send(.increment) { $0.count = 5 }
        intPublisher.send(completion: .finished)
        await observeTask?.value

        #expect(await model.state == .init(count: 5))
        await model.finish()
    }
}

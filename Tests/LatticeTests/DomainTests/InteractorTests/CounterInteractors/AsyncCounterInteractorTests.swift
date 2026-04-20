import Foundation
import Testing

@testable import Lattice

@Suite
@MainActor
final class AsyncCounterInteractorTests {

    @Test func asyncWork() async {
        let model = makeTestViewModel(
            initialDomainState: AsyncCounterState(count: 0),
            interactor: AsyncCounterInteractor()
        )

        _ = await model.send(.increment) {
            $0.count = 1
        }

        let task = await model.send(.asyncIncrement) { _ in }
        await task.finish()

        await model.receive(.increment) {
            $0.count = 2
        }

        _ = await model.send(.increment) {
            $0.count = 3
        }

        #expect(model.domainState == .init(count: 3))
    }
}

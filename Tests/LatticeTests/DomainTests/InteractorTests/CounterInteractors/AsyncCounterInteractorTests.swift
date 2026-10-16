import Foundation
import Testing

@testable import Lattice

@Suite
struct AsyncCounterInteractorTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func asyncWork() async {
        let model = await TestModel(
            initialState: AsyncCounterState(count: 0),
            feature: Feature(interactor: AsyncCounterInteractor())
        )

        await model.send(.increment) { $0.count = 1 }

        // The effect's preamble sends `.increment`: it is pending once the send's task is done.
        await model.send(.asyncIncrement)?.value
        await model.receive(.increment) { $0.count = 2 }

        await model.send(.increment) { $0.count = 3 }

        #expect(await model.state == .init(count: 3))
        await model.finish()
    }
}

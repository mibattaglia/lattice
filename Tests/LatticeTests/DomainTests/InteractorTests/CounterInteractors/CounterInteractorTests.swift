import Foundation
import Testing

@testable import Lattice

@Suite
struct CounterInteractorTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func increment() async {
        let model = await makeModel()

        await model.send(.increment) { $0.count = 1 }
        await model.send(.increment) { $0.count = 2 }
        await model.send(.increment) { $0.count = 3 }

        #expect(await model.state == .init(count: 3))
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func decrement() async {
        let model = await makeModel()

        await model.send(.increment) { $0.count = 1 }
        await model.send(.increment) { $0.count = 2 }
        await model.send(.increment) { $0.count = 3 }
        await model.send(.decrement) { $0.count = 2 }
        await model.send(.decrement) { $0.count = 1 }
        await model.send(.decrement) { $0.count = 0 }

        #expect(await model.state == .init(count: 0))
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func reset() async {
        let model = await makeModel()

        await model.send(.increment) { $0.count = 1 }
        await model.send(.increment) { $0.count = 2 }
        await model.send(.increment) { $0.count = 3 }
        await model.send(.reset) { $0.count = 0 }

        #expect(await model.state == .init(count: 0))
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    private func makeModel(
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestModel<Feature<CounterAction, CounterState>> {
        await TestModel(
            initialState: CounterState(count: 0),
            feature: Feature(interactor: CounterInteractor()),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
}

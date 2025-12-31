@preconcurrency import Combine
import Foundation
import Testing

@testable import UnoArchitecture

@Suite
@MainActor
final class HotCounterInteractorTests {

    @Test func asyncWork() async throws {
        let harness = await InteractorTestHarness(HotCounterInteractor())

        harness.send(.increment)
        try await harness.waitForStates(count: 2)

        let intPublisher = CurrentValueSubject<Int, Never>(1)
        harness.send(.observe(intPublisher.eraseToAnyPublisher()))
        try await harness.waitForStates(count: 3)

        intPublisher.send(2)
        try await harness.waitForStates(count: 4)

        harness.send(.increment)
        intPublisher.send(completion: .finished)
        harness.finish()

        try await harness.assertStates([
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 4),
            .init(count: 5),
        ])
    }
}

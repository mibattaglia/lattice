@preconcurrency import Combine
import Foundation
import Testing

@testable import Lattice

@Suite
@MainActor
final class HotCounterInteractorTests {

    @Test func asyncWork() async throws {
        let model = makeTestViewModel(
            initialDomainState: HotCounterInteractor.DomainState(count: 0),
            interactor: HotCounterInteractor()
        )

        _ = try await model.send(.increment) {
            $0.count = 1
        }

        let intPublisher = CurrentValueSubject<Int, Never>(1)
        let observeTask = try await model.send(.observe(intPublisher.eraseToAnyPublisher())) { _ in }

        try await model.receive(
            {
                if case .addValue(1) = $0 {
                    return true
                }
                return false
            }
        ) {
            $0.count = 2
        }

        intPublisher.send(2)
        try await model.receive(
            {
                if case .addValue(2) = $0 {
                    return true
                }
                return false
            }
        ) {
            $0.count = 4
        }

        _ = try await model.send(.increment) {
            $0.count = 5
        }
        intPublisher.send(completion: .finished)
        try await observeTask.finish()

        #expect(model.domainState == .init(count: 5))
    }
}

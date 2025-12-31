import Foundation
import Testing

@testable import UnoArchitecture

@Suite
@MainActor
struct MergeManyTests {
    @Test
    func mergeManyInOrder_SameType() async throws {
        let many = Interactors.MergeMany(
            interactors: [
                DoubleInteractor(),
                DoubleInteractor(),
                DoubleInteractor(),
            ]
        )

        let recorder = AsyncStreamRecorder<Int>()
        let (actionStream, actionCont) = AsyncStream<Int>.makeStream()

        recorder.record(many.interact(actionStream))

        actionCont.yield(4)
        actionCont.finish()

        try await recorder.waitForEmissions(count: 3, timeout: .milliseconds(500))
        #expect(recorder.values == [8, 8, 8])
    }

    @Test
    func mergeManyInOrder_TypeErased() async throws {
        let many = Interactors.MergeMany(
            interactors: [
                DoubleInteractor().eraseToAnyInteractor(),
                TripleInteractor().eraseToAnyInteractor(),
                DoubleInteractor().eraseToAnyInteractor(),
            ]
        )

        let recorder = AsyncStreamRecorder<Int>()
        let (actionStream, actionCont) = AsyncStream<Int>.makeStream()

        recorder.record(many.interact(actionStream))

        actionCont.yield(4)
        actionCont.finish()

        try await recorder.waitForEmissions(count: 3, timeout: .milliseconds(500))
        #expect(recorder.values == [8, 12, 8])
    }
}

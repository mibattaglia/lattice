import Foundation
import Testing

@testable import UnoArchitecture

@Suite
@MainActor
struct MergeTests {
    @Test
    func mergeTwo() async throws {
        let merge = Interactors.Merge(
            TripleInteractor(),
            DoubleInteractor()
        )

        let recorder = AsyncStreamRecorder<Int>()
        let (actionStream, actionCont) = AsyncStream<Int>.makeStream()

        recorder.record(merge.interact(actionStream))

        actionCont.yield(3)
        actionCont.finish()

        try await recorder.waitForEmissions(count: 2, timeout: .milliseconds(0.5))
        #expect(recorder.values == [9, 6])
    }
}

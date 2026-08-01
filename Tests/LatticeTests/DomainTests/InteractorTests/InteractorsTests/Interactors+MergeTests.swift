import Foundation
import Testing

@testable import Lattice

@Suite
@MainActor
struct MergeTests {
    @Test
    func mergeTwo() throws {
        var results: [Int] = []

        let merge = Interactors.Merge(
            TripleInteractor(),
            DoubleInteractor()
        )

        let effects: Effects<Int, Int> = _detachedEffectsHandle(path: GraphPath())

        var state = 0

        // TripleInteractor processes first: state = 3 * 3 = 9
        TripleInteractor().interact(state: &state, action: 3, effects: effects)
        results.append(state)

        state = 0
        // DoubleInteractor processes: state = 3 * 2 = 6
        DoubleInteractor().interact(state: &state, action: 3, effects: effects)
        results.append(state)

        #expect(results == [9, 6])

        // Also verify merge calls both, in order: final state is from the last interactor.
        state = 0
        merge.interact(state: &state, action: 3, effects: effects)
        #expect(state == 6)
    }
}

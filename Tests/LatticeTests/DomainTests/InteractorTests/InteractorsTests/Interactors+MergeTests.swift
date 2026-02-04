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

        var state = 0

        // TripleInteractor processes first: state = 3 * 3 = 9
        _ = TripleInteractor().interact(state: &state, action: 3)
        results.append(state)

        state = 0
        // DoubleInteractor processes: state = 3 * 2 = 6
        _ = DoubleInteractor().interact(state: &state, action: 3)
        results.append(state)

        #expect(results == [9, 6])

        // Also verify merge calls both
        state = 0
        let emission = merge.interact(state: &state, action: 3)
        // Final state is from last interactor (DoubleInteractor)
        #expect(state == 6)
        // Emission should be merged
        if case .merge(let emissions) = emission.kind {
            #expect(emissions.count == 2)
        } else {
            Issue.record("Expected merged emissions")
        }
    }
}

import Foundation
import Testing

@testable import Lattice

@Suite
@MainActor
struct MergeManyTests {
    @Test
    func mergeManyInOrder_SameType() throws {
        var results: [Int] = []
        let effects: Effects<Int, Int> = _detachedEffectsHandle(path: GraphPath())

        // Test each interactor individually
        for _ in 0..<3 {
            var state = 0
            DoubleInteractor().interact(state: &state, action: 4, effects: effects)
            results.append(state)
        }

        #expect(results == [8, 8, 8])

        // Also verify MergeMany calls all three
        let many = Interactors.MergeMany(
            interactors: [
                DoubleInteractor(),
                DoubleInteractor(),
                DoubleInteractor(),
            ]
        )

        var state = 0
        many.interact(state: &state, action: 4, effects: effects)
        #expect(state == 8)
    }

    @Test
    func mergeManyInOrder_TypeErased() throws {
        var results: [Int] = []
        let effects: Effects<Int, Int> = _detachedEffectsHandle(path: GraphPath())

        // Test each interactor individually in order
        var state = 0
        DoubleInteractor().interact(state: &state, action: 4, effects: effects)
        results.append(state)

        state = 0
        TripleInteractor().interact(state: &state, action: 4, effects: effects)
        results.append(state)

        state = 0
        DoubleInteractor().interact(state: &state, action: 4, effects: effects)
        results.append(state)

        #expect(results == [8, 12, 8])

        // Also verify MergeMany calls all three, in order: state reflects the last child.
        let many = Interactors.MergeMany(
            interactors: [
                DoubleInteractor().eraseToAnyInteractor(),
                TripleInteractor().eraseToAnyInteractor(),
                DoubleInteractor().eraseToAnyInteractor(),
            ]
        )

        state = 0
        many.interact(state: &state, action: 4, effects: effects)
        #expect(state == 8)
    }
}

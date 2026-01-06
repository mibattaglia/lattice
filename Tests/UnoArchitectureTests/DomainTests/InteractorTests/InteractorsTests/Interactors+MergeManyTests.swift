import Foundation
import Testing

@testable import UnoArchitecture

@Suite
@MainActor
struct MergeManyTests {
    @Test
    func mergeManyInOrder_SameType() throws {
        var results: [Int] = []

        // Test each interactor individually
        for _ in 0..<3 {
            var state = 0
            _ = DoubleInteractor().interact(state: &state, action: 4)
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
        let emission = many.interact(state: &state, action: 4)
        #expect(state == 8)
        if case .merge(let emissions) = emission.kind {
            #expect(emissions.count == 3)
        } else {
            Issue.record("Expected merged emissions")
        }
    }

    @Test
    func mergeManyInOrder_TypeErased() throws {
        var results: [Int] = []

        // Test each interactor individually in order
        var state = 0
        _ = DoubleInteractor().interact(state: &state, action: 4)
        results.append(state)

        state = 0
        _ = TripleInteractor().interact(state: &state, action: 4)
        results.append(state)

        state = 0
        _ = DoubleInteractor().interact(state: &state, action: 4)
        results.append(state)

        #expect(results == [8, 12, 8])

        // Also verify MergeMany calls all three
        let many = Interactors.MergeMany(
            interactors: [
                DoubleInteractor().eraseToAnyInteractor(),
                TripleInteractor().eraseToAnyInteractor(),
                DoubleInteractor().eraseToAnyInteractor(),
            ]
        )

        state = 0
        let emission = many.interact(state: &state, action: 4)
        #expect(state == 8)
        if case .merge(let emissions) = emission.kind {
            #expect(emissions.count == 3)
        } else {
            Issue.record("Expected merged emissions")
        }
    }
}

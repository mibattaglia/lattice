import Foundation
import Testing

@testable import Lattice

@Suite
@MainActor
struct MergeManyTests {
    @Test
    func mergeManyInOrder_SameType() throws {
        var results: [Int] = []

        // Test each interactor individually
        for _ in 0..<3 {
            let single = makeViewModel(DoubleInteractor())
            single.sendViewEvent(4)
            results.append(single.value)
        }

        #expect(results == [8, 8, 8])

        // Also verify MergeMany calls all three
        let many = makeViewModel(
            Interactors.MergeMany(
                interactors: [
                    DoubleInteractor(),
                    DoubleInteractor(),
                    DoubleInteractor(),
                ]
            )
        )

        let task = many.sendViewEvent(4)
        #expect(many.value == 8)
        #expect(task != nil)
        #expect(many.effectLog == ["double", "double", "double"])
    }

    @Test
    func mergeManyInOrder_TypeErased() throws {
        var results: [Int] = []

        // Test each interactor individually in order
        let first = makeViewModel(DoubleInteractor())
        first.sendViewEvent(4)
        results.append(first.value)

        let second = makeViewModel(TripleInteractor())
        second.sendViewEvent(4)
        results.append(second.value)

        let third = makeViewModel(DoubleInteractor())
        third.sendViewEvent(4)
        results.append(third.value)

        #expect(results == [8, 12, 8])

        // Also verify MergeMany calls all three
        let many = makeViewModel(
            Interactors.MergeMany(
                interactors: [
                    DoubleInteractor().eraseToAnyInteractor(),
                    TripleInteractor().eraseToAnyInteractor(),
                    DoubleInteractor().eraseToAnyInteractor(),
                ]
            )
        )

        let task = many.sendViewEvent(4)
        #expect(many.value == 8)
        #expect(task != nil)
        #expect(many.effectLog == ["double", "triple", "double"])
    }

    private func makeViewModel<I: Interactor<ArithmeticState, Int>>(
        _ interactor: I
    ) -> ViewModel<Feature<Int, ArithmeticState>> {
        ViewModel(initialState: ArithmeticState(), feature: Feature(interactor: interactor))
    }
}

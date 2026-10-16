import Foundation
import Testing

@testable import Lattice

@Suite
struct MergeManyTests {
    /// Three instances of one interactor type: each alone writes 8; merged, all three run and start
    /// their effects in order before `send` returns.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func mergeManyRunsInstancesOfOneTypeInOrder() async {
        for _ in 0..<3 {
            let single = await makeArithmeticModel(DoubleInteractor())
            await single.send(4) {
                $0.value = 8
                $0.performed = ["double"]
            }
            await single.finish()
        }

        let many = await makeArithmeticModel(
            Interactors.MergeMany(interactors: [DoubleInteractor(), DoubleInteractor(), DoubleInteractor()])
        )
        let task = await many.send(4) {
            $0.value = 8
            $0.performed = ["double", "double", "double"]
        }

        #expect(task != nil)
        await many.finish()
    }

    /// Type-erased interactors of different types: each alone writes its own value; merged, they run
    /// in order, so the last one's value wins, and their effects start in the same order.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func mergeManyRunsTypeErasedInteractorsInOrder() async {
        let first = await makeArithmeticModel(DoubleInteractor())
        await first.send(4) {
            $0.value = 8
            $0.performed = ["double"]
        }
        await first.finish()

        let second = await makeArithmeticModel(TripleInteractor())
        await second.send(4) {
            $0.value = 12
            $0.performed = ["triple"]
        }
        await second.finish()

        let third = await makeArithmeticModel(DoubleInteractor())
        await third.send(4) {
            $0.value = 8
            $0.performed = ["double"]
        }
        await third.finish()

        let many = await makeArithmeticModel(
            Interactors.MergeMany(
                interactors: [
                    DoubleInteractor().eraseToAnyInteractor(),
                    TripleInteractor().eraseToAnyInteractor(),
                    DoubleInteractor().eraseToAnyInteractor(),
                ]
            )
        )
        let task = await many.send(4) {
            $0.value = 8
            $0.performed = ["double", "triple", "double"]
        }

        #expect(task != nil)
        await many.finish()
    }
}

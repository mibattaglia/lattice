import Foundation
import Testing

@testable import Lattice

@FeatureState
struct RendezvousState: Equatable, Sendable {
    var metPartner = false
}

enum RendezvousAction: Equatable, Sendable {
    case meet
}

/// Where the effects of two models meet: each signals its own semaphore, then waits up to five
/// seconds for its partner's. Synchronous, because `DispatchSemaphore.wait` is unavailable from async
/// code, and blocking on purpose: a waiting effect holds its model's executor, so the two meet only
/// if the models run on executors of their own, at the same time.
final class Rendezvous: @unchecked Sendable {
    private let arrivals = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]

    /// Signals that `side` (0 or 1) arrived, then waits for the other side; returns whether it came.
    func arrive(_ side: Int) -> Bool {
        arrivals[side].signal()
        return arrivals[1 - side].wait(timeout: .now() + 5) == .success
    }
}

/// `.meet`'s effect waits at the rendezvous in its preamble, then records that it met its partner.
@Interactor<RendezvousState, RendezvousAction>
struct RendezvousInteractor {
    let rendezvous: Rendezvous
    let side: Int

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .meet:
                effects.perform {
                    if rendezvous.arrive(side) {
                        try effects.modify { $0.metPartner = true }
                    }
                }
            }
        }
    }
}

/// Each `TestModel` and each `ActorModel` runs its feature on an executor of its own
/// (`DefaultIsolation`), so two models run their effects in parallel: two effects that each wait for
/// the other meet. Were the models' effects serialized on one executor, the first effect would wait
/// out the timeout alone and the second would meet nobody.
@Suite(.enabled(if: ProcessInfo.processInfo.activeProcessorCount > 1, "needs two cores"))
struct ParallelismTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func twoTestModelsRunTheirEffectsAtTheSameTime() async {
        let rendezvous = Rendezvous()
        let first = await TestModel(
            initialState: RendezvousState(),
            feature: Feature(interactor: RendezvousInteractor(rendezvous: rendezvous, side: 0))
        )
        let second = await TestModel(
            initialState: RendezvousState(),
            feature: Feature(interactor: RendezvousInteractor(rendezvous: rendezvous, side: 1))
        )

        async let firstMeeting = first.send(.meet) { $0.metPartner = true }  // the effect met its partner inside `send`
        async let secondMeeting = second.send(.meet) { $0.metPartner = true }
        _ = await (firstMeeting, secondMeeting)

        await first.finish()
        await second.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func twoActorModelsRunTheirEffectsAtTheSameTime() async {
        let rendezvous = Rendezvous()
        let first = await ActorModel(
            initialState: RendezvousState(),
            feature: Feature(interactor: RendezvousInteractor(rendezvous: rendezvous, side: 0))
        )
        let second = await ActorModel(
            initialState: RendezvousState(),
            feature: Feature(interactor: RendezvousInteractor(rendezvous: rendezvous, side: 1))
        )

        async let firstMeeting = first.send(.meet)
        async let secondMeeting = second.send(.meet)
        _ = await (firstMeeting, secondMeeting)

        #expect(await first.state.metPartner)
        #expect(await second.state.metPartner)
    }
}

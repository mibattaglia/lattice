import Foundation
import Testing

@testable import Lattice

@FeatureState
struct ExecutorProbeState: Equatable, Sendable {}

enum ExecutorProbeAction: Equatable, Sendable {
    case probe
}

/// `.probe`'s effect reports, from its preamble, the isolation it runs on.
@Interactor<ExecutorProbeState, ExecutorProbeAction>
struct ExecutorProbeInteractor {
    let isolations: AsyncStream<ObjectIdentifier?>.Continuation

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .probe:
                effects.perform {
                    isolations.yield(#isolation.map { ObjectIdentifier($0) })
                }
            }
        }
    }
}

/// Each `TestModel` and each `ActorModel` runs its effects on a serial executor of its own, so the
/// effects of two models can run in parallel.
@Suite
struct ParallelismTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func twoTestModelsRunTheirEffectsOnExecutorsOfTheirOwn() async {
        let (isolations, continuation) = AsyncStream.makeStream(of: ObjectIdentifier?.self)
        let first = await TestModel(
            initialState: ExecutorProbeState(),
            feature: Feature(interactor: ExecutorProbeInteractor(isolations: continuation))
        )
        let second = await TestModel(
            initialState: ExecutorProbeState(),
            feature: Feature(interactor: ExecutorProbeInteractor(isolations: continuation))
        )

        await first.send(.probe)
        await second.send(.probe)
        await first.finish()
        await second.finish()

        continuation.finish()
        let reported = await isolations.reduce(into: []) { $0.append($1) }
        #expect(reported.count == 2)
        #expect(reported.allSatisfy { $0 != nil })
        #expect(Set(reported).count == 2)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func twoActorModelsRunTheirEffectsOnExecutorsOfTheirOwn() async {
        let (isolations, continuation) = AsyncStream.makeStream(of: ObjectIdentifier?.self)
        let first = await ActorModel(
            initialState: ExecutorProbeState(),
            feature: Feature(interactor: ExecutorProbeInteractor(isolations: continuation))
        )
        let second = await ActorModel(
            initialState: ExecutorProbeState(),
            feature: Feature(interactor: ExecutorProbeInteractor(isolations: continuation))
        )

        await first.send(.probe)?.value
        await second.send(.probe)?.value

        continuation.finish()
        let reported = await isolations.reduce(into: []) { $0.append($1) }
        #expect(reported.count == 2)
        #expect(reported.allSatisfy { $0 != nil })
        #expect(Set(reported).count == 2)
    }
}

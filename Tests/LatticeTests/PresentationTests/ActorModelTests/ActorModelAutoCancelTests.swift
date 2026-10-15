import CasePaths
import Clocks
import Foundation
import Testing

@testable import Lattice

// Every fixture is declared at file scope, so the interactors and their effect literals are
// nonisolated, as `ActorModel` requires. The sleeping effects log only in their preambles and from
// their cancellation handlers, both inside a `send` (the one that starts them and the one that
// cancels them), so the log is settled whenever a `send` has returned.

// MARK: - Child

@FeatureState
struct ActorModelChildState: Equatable, Sendable {
    var starts = 0
}

@CasePathable
enum ActorModelChildAction: Equatable, Sendable {
    case start
    case other
}

/// `.start` performs an effect that sleeps until cancelled and logs its cancellation synchronously.
@Interactor<ActorModelChildState, ActorModelChildAction>
struct ActorModelChildInteractor {
    let name: String
    let log: EffectLog
    let clock: TestClock<Duration>

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .start:
                state.starts += 1
                let start = state.starts
                effects.perform {
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "\(name) start #\(start) cancelled")
                }
            case .other:
                break
            }
        }
    }
}

// MARK: - Parent

@FeatureState
struct ActorModelAutoCancelState: Equatable, Sendable {
    var a = ActorModelChildState()
    var b = ActorModelChildState()
    var results: [String] = []
}

@CasePathable
enum ActorModelAutoCancelAction: Equatable, Sendable {
    case a(ActorModelChildAction)
    case b(ActorModelChildAction)
    case search(String)
    case go
    case load
    case reload
    case cancelLoad
    case other
}

@Interactor<ActorModelAutoCancelState, ActorModelAutoCancelAction>
struct ActorModelAutoCancelInteractor {
    @EffectID var load
    let log: EffectLog
    let clock: TestClock<Duration>
    let gate: SendableEffectGate

    var body: some InteractorOf<Self> {
        Interactors.When(state: \.a, action: \.a) {
            ActorModelChildInteractor(name: "a", log: log, clock: clock)
        }
        Interactors.When(state: \.b, action: \.b) {
            ActorModelChildInteractor(name: "b", log: log, clock: clock)
        }
        Interact { _, action, effects in
            switch action {
            case .search(let query):
                effects.perform {
                    try await withTaskCancellationHandler {
                        try await gate.pass()
                    } onCancel: { [log] in
                        log.append("search \(query) cancelled")
                    }
                    try effects.modify { $0.results.append(query) }
                }

            case .go:
                effects.perform {
                    log.append("go effect 1 started")
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "go effect 1 cancelled")
                }

            case .load:
                effects.perform(id: load) {
                    log.append("load started")
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "load cancelled")
                }

            case .reload:
                effects.perform(id: load) {
                    log.append("reload started")
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "reload cancelled")
                }

            case .cancelLoad:
                effects.cancel(load)

            case .a, .b, .other:
                break
            }
        }
        // Merged with the interactor above: both perform for `.go`.
        Interact { _, action, effects in
            if case .go = action {
                effects.perform {
                    log.append("go effect 2 started")
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "go effect 2 cancelled")
                }
            }
        }
    }
}

// MARK: - Tests

/// Auto-cancel under `ActorModel`: anonymous effects are cancelled when the enum-tag path that
/// performed them is handled again (the root action's case, then one child case per `When` hop);
/// `@EffectID` effects are replaced per key and cancelled explicitly, from any case.
@Suite
struct ActorModelAutoCancelTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    private func makeModel(
        log: EffectLog,
        gate: SendableEffectGate = SendableEffectGate()
    ) async -> ActorModel<Feature<ActorModelAutoCancelAction, ActorModelAutoCancelState>> {
        await ActorModel(
            initialState: ActorModelAutoCancelState(),
            feature: Feature(interactor: ActorModelAutoCancelInteractor(log: log, clock: TestClock(), gate: gate))
        )
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func reHandlingAnActionCaseCancelsOnlyThatCasesPreviousEffects() async {
        let log = EffectLog()
        let gate = SendableEffectGate()
        let model = await makeModel(log: log, gate: gate)

        let first = await model.send(.search("a"))
        #expect(await model.send(.other) == nil)  // another case: cancels nothing
        #expect(log.entries.isEmpty)
        let second = await model.send(.search("b"))
        #expect(log.entries == ["search a cancelled"])

        // Both searches resume; the cancelled one stops at its cancellation-aware suspension point.
        gate.open()
        await first?.value
        await second?.value
        #expect(await model.state.results == ["b"])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func reHandlingAChildCaseThroughAWhenKeyPathCancelsOnlyThatChildCasesEffects() async {
        let log = EffectLog()
        let model = await makeModel(log: log)

        await model.send(.a(.start))
        await model.send(.a(.other))  // another case of the same child
        await model.send(.other)  // another root case
        await model.send(.b(.start))  // the same case of a sibling child
        #expect(log.entries.isEmpty)

        await model.send(.a(.start))
        #expect(log.entries == ["a start #1 cancelled"])
        #expect(await model.state.a.starts == 2)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func mergedInteractorsBothStartTheirEffectsAndReHandlingTheCaseCancelsBoth() async {
        let log = EffectLog()
        let model = await makeModel(log: log)

        await model.send(.go)
        #expect(log.entries == ["go effect 1 started", "go effect 2 started"])

        await model.send(.go)
        let entries = log.entries
        #expect(entries.count == 6)
        #expect(entries.dropFirst(2).prefix(2).sorted() == ["go effect 1 cancelled", "go effect 2 cancelled"])
        #expect(entries.suffix(2) == ["go effect 1 started", "go effect 2 started"])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func identifiedEffectIsReplacedPerKeyAndCancelledFromAnotherCase() async {
        let log = EffectLog()
        let model = await makeModel(log: log)

        await model.send(.load)
        #expect(log.entries == ["load started"])

        // Another case performs under the same key: the previous effect is cancelled before the new
        // one starts.
        await model.send(.reload)
        #expect(log.entries == ["load started", "load cancelled", "reload started"])

        await model.send(.cancelLoad)
        #expect(log.entries == ["load started", "load cancelled", "reload started", "reload cancelled"])
    }
}

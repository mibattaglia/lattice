import CasePaths
import Foundation
import Testing

@testable import Lattice

// Every fixture is declared at file scope, so the interactors and their effect literals are
// nonisolated, as `ActorModel` requires. Each effect waits for its own answer from a slow
// dependency, then records that it completed. The answer ends on cancellation too, so an effect that
// auto-cancel or a replacement cancelled while it waited never completes, and the test can await
// every task. A test opens answers in two rounds when it shows what a send left running.

/// A slow dependency's answers, one per request, each a gate the test opens.
final class ActorModelAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [String: Gate] = [:]

    func answer(_ request: String) -> Gate {
        lock.withLock {
            if let gate = gates[request] { return gate }
            let gate = Gate()
            gates[request] = gate
            return gate
        }
    }

    func open(_ requests: String...) {
        for request in requests {
            answer(request).open()
        }
    }
}

// MARK: - Child

@FeatureState
struct ActorModelChildState: Equatable, Sendable {
    var starts = 0
    var completed: [Int] = []
}

@CasePathable
enum ActorModelChildAction: Equatable, Sendable {
    case start
    case other
}

/// `.start` counts, then performs an effect that waits for the answer to "<name> #<start>" and
/// records the start's number in `completed`.
@Interactor<ActorModelChildState, ActorModelChildAction>
struct ActorModelChildInteractor {
    let name: String
    let answers: ActorModelAnswers

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .start:
                state.starts += 1
                let start = state.starts
                effects.perform {
                    try await answers.answer("\(name) #\(start)").pass()
                    try effects.modify { $0.completed.append(start) }
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
    var goRuns = 0
    var goStarted: [String] = []
    var goCompleted: Set<String> = []
    var loadRuns = 0
    var loadsCompleted: [String] = []
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
    let answers: ActorModelAnswers

    var body: some InteractorOf<Self> {
        Interactors.When(state: \.a, action: \.a) {
            ActorModelChildInteractor(name: "a", answers: answers)
        }
        Interactors.When(state: \.b, action: \.b) {
            ActorModelChildInteractor(name: "b", answers: answers)
        }
        Interact { state, action, effects in
            switch action {
            case .search(let query):
                effects.perform {
                    try await answers.answer("search \(query)").pass()
                    try effects.modify { $0.results.append(query) }
                }

            case .go:
                state.goRuns += 1
                let name = "go effect 1 of run \(state.goRuns)"
                effects.perform {
                    try effects.modify { $0.goStarted.append(name) }
                    try await answers.answer(name).pass()
                    try effects.modify { $0.goCompleted.insert(name) }
                }

            case .load:
                state.loadRuns += 1
                let name = "load #\(state.loadRuns)"
                effects.perform(id: load) {
                    try await answers.answer(name).pass()
                    try effects.modify { $0.loadsCompleted.append(name) }
                }

            case .reload:
                state.loadRuns += 1
                let name = "reload #\(state.loadRuns)"
                effects.perform(id: load) {
                    try await answers.answer(name).pass()
                    try effects.modify { $0.loadsCompleted.append(name) }
                }

            case .cancelLoad:
                effects.cancel(load)

            case .a, .b, .other:
                break
            }
        }
        // Merged with the interactor above: both perform for `.go`.
        Interact { state, action, effects in
            if case .go = action {
                let name = "go effect 2 of run \(state.goRuns)"
                effects.perform {
                    try effects.modify { $0.goStarted.append(name) }
                    try await answers.answer(name).pass()
                    try effects.modify { $0.goCompleted.insert(name) }
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
        answers: ActorModelAnswers
    ) async -> ActorModel<Feature<ActorModelAutoCancelAction, ActorModelAutoCancelState>> {
        await ActorModel(
            initialState: ActorModelAutoCancelState(),
            feature: Feature(interactor: ActorModelAutoCancelInteractor(answers: answers))
        )
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func reHandlingAnActionCaseCancelsOnlyThatCasesPreviousEffects() async {
        let answers = ActorModelAnswers()
        let model = await makeModel(answers: answers)

        let a = await model.send(.search("a"))
        #expect(await model.send(.other) == nil)  // another case: starts nothing
        answers.open("search a")
        await a?.value
        #expect(await model.state.results == ["a"])  // and cancels nothing

        let b = await model.send(.search("b"))
        await model.send(.other)
        let c = await model.send(.search("c"))  // re-handles `.search`: cancels "b" while it waits
        answers.open("search b", "search c")
        await b?.value
        await c?.value
        #expect(await model.state.results == ["a", "c"])  // "b" never completed
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func reHandlingAChildCaseThroughAWhenKeyPathCancelsOnlyThatChildCasesEffects() async {
        let answers = ActorModelAnswers()
        let model = await makeModel(answers: answers)

        let a1 = await model.send(.a(.start))
        await model.send(.a(.other))  // another case of the same child
        await model.send(.other)  // another root case
        let b1 = await model.send(.b(.start))  // the same case of a sibling child
        answers.open("a #1", "b #1")
        await a1?.value
        await b1?.value
        #expect(await model.state.a.completed == [1])  // none of those sends cancelled a #1
        #expect(await model.state.b.completed == [1])

        let a2 = await model.send(.a(.start))
        await model.send(.a(.other))
        await model.send(.other)
        let b2 = await model.send(.b(.start))
        let a3 = await model.send(.a(.start))  // re-handles `.a(.start)`: cancels a #2
        answers.open("a #2", "b #2", "a #3")
        await a2?.value
        await b2?.value
        await a3?.value
        let state = await model.state
        #expect(state.a.starts == 3)
        #expect(state.a.completed == [1, 3])  // a #2 never completed
        #expect(state.b.completed == [1, 2])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func mergedInteractorsBothStartTheirEffectsAndReHandlingTheCaseCancelsBoth() async {
        let answers = ActorModelAnswers()
        let model = await makeModel(answers: answers)

        let run1 = await model.send(.go)
        // Both preambles ran inside `send`, in merge order; then both effects wait.
        #expect(await model.state.goStarted == ["go effect 1 of run 1", "go effect 2 of run 1"])

        let run2 = await model.send(.go)  // cancels both effects of run 1
        answers.open("go effect 1 of run 1", "go effect 2 of run 1", "go effect 1 of run 2", "go effect 2 of run 2")
        await run1?.value
        await run2?.value
        let state = await model.state
        #expect(
            state.goStarted == [
                "go effect 1 of run 1", "go effect 2 of run 1", "go effect 1 of run 2", "go effect 2 of run 2",
            ]
        )
        #expect(state.goCompleted == ["go effect 1 of run 2", "go effect 2 of run 2"])  // not run 1's
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func identifiedEffectIsReplacedPerKeyAndCancelledFromAnotherCase() async {
        let answers = ActorModelAnswers()
        let model = await makeModel(answers: answers)

        let first = await model.send(.load)
        answers.open("load #1")
        await first?.value
        #expect(await model.state.loadsCompleted == ["load #1"])  // left alone, a load completes

        let second = await model.send(.load)
        let third = await model.send(.reload)  // another case performs under the same key: replaces load #2
        answers.open("load #2")
        await second?.value
        await model.send(.cancelLoad)  // cancels reload #3, from another case
        answers.open("reload #3")
        await third?.value
        #expect(await model.state.loadsCompleted == ["load #1"])  // neither load #2 nor reload #3 completed
    }
}

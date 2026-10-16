import CasePaths
import Foundation
import Testing

@testable import Lattice

// Every fixture is declared at file scope, so the interactors and their effect literals are
// nonisolated, as `TestModel` requires. Each effect sleeps on an `EffectClock`, then records that it
// completed: an effect that auto-cancel cancelled throws at its sleep and never completes, so after
// `advance`, `expect` shows which effects auto-cancel left running. A test that shows what a send
// leaves running advances twice: first past the effects those sends left alone, then past the ones
// a re-handled case cancelled.

private let effectDuration: Duration = .seconds(1)

// MARK: - Child

@FeatureState
struct AutoCancelChildState: Equatable {
    var starts = 0
    var completed: [Int] = []
}

@CasePathable
enum AutoCancelChildAction: Equatable {
    case start
    case other
}

/// `.start` counts, then performs an effect that sleeps and records the start's number in
/// `completed`.
@Interactor<AutoCancelChildState, AutoCancelChildAction>
struct AutoCancelChildInteractor {
    let clock: EffectClock

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .start:
                state.starts += 1
                let start = state.starts
                effects.perform {
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completed.append(start) }
                }
            case .other:
                break
            }
        }
    }
}

// MARK: - Key-path parent

@FeatureState
struct AutoCancelState: Equatable {
    var a = AutoCancelChildState()
    var b = AutoCancelChildState()
    var results: [String] = []
    var goRuns = 0
    var goStarted: [String] = []
    var goCompleted: Set<String> = []
}

@CasePathable
enum AutoCancelAction: Equatable {
    case a(AutoCancelChildAction)
    case b(AutoCancelChildAction)
    case search(String)
    case go
    case other
}

@Interactor<AutoCancelState, AutoCancelAction>
struct AutoCancelInteractor {
    let clock: EffectClock

    var body: some InteractorOf<Self> {
        Interactors.When(state: \.a, action: \.a) {
            AutoCancelChildInteractor(clock: clock)
        }
        Interactors.When(state: \.b, action: \.b) {
            AutoCancelChildInteractor(clock: clock)
        }
        Interact { state, action, effects in
            switch action {
            case .search(let query):
                effects.perform {
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.results.append(query) }
                }

            case .go:
                state.goRuns += 1
                let name = "go effect 1 of run \(state.goRuns)"
                effects.perform {
                    try effects.modify { $0.goStarted.append(name) }
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.goCompleted.insert(name) }
                }

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
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.goCompleted.insert(name) }
                }
            }
        }
    }
}

/// A parent that performs its own effect when it handles the child action `.a(.start)`.
@Interactor<AutoCancelState, AutoCancelAction>
struct ChildActionObservingInteractor {
    let clock: EffectClock

    var body: some InteractorOf<Self> {
        Interactors.When(state: \.a, action: \.a) {
            AutoCancelChildInteractor(clock: clock)
        }
        Interact { _, action, effects in
            if case .a(.start) = action {
                effects.perform {
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.results.append("parent effect for a.start") }
                }
            }
        }
    }
}

// MARK: - Case-path parent

@CasePathable
enum AutoCancelModeAction: Equatable {
    case active(AutoCancelChildAction)
    case activate(starts: Int)
    case deactivate
    case other
}

@Interactor<AutoCancelModeState, AutoCancelModeAction>
struct AutoCancelModeInteractor {
    let clock: EffectClock

    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .activate(let starts):
                state = .active(AutoCancelChildState(starts: starts))
            case .deactivate:
                state = .idle
            case .active, .other:
                break
            }
        }
        Interactors.When(state: \.active, action: \.active) {
            AutoCancelChildInteractor(clock: clock)
        }
    }
}

// MARK: - Enum tags

indirect enum TagProbe {
    case leaf(Int)
    case pair(TagProbe, TagProbe)
    case labeled(String, [Int])
    case empty
}

private struct NotAnEnum {}

@FeatureState
struct TreeState: Equatable {
    var nodes = 0
    var completedNodes: [Int] = []
    var completedLeaves: [String] = []
}

indirect enum TreeAction {
    case leaf(String)
    case node(TreeAction, TreeAction)
}

/// Every action performs an effect that sleeps, then records the leaf's name or the node's number.
@Interactor<TreeState, TreeAction>
struct TreeInteractor {
    let clock: EffectClock

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .leaf(let name):
                effects.perform {
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completedLeaves.append(name) }
                }
            case .node:
                state.nodes += 1
                let node = state.nodes
                effects.perform {
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completedNodes.append(node) }
                }
            }
        }
    }
}

// MARK: - Tests

/// Anonymous effects are cancelled when the enum-tag path that performed them is handled again:
/// the root action's case, then one child case per `When` hop.
@Suite
struct AutoCancelTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    private func makeModel(
        clock: EffectClock,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestModel<Feature<AutoCancelAction, AutoCancelState>> {
        await TestModel(
            initialState: AutoCancelState(),
            feature: Feature(interactor: AutoCancelInteractor(clock: clock)),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func reHandlingAnActionCaseCancelsOnlyThatCasesPreviousEffects() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.search("a"))
        #expect(await model.send(.other) == nil)  // another case: starts nothing
        await model.advance(clock, by: effectDuration)
        await model.expect { $0.results = ["a"] }  // and cancels nothing

        await model.send(.search("b"))
        await model.send(.other)
        await model.send(.search("c"))  // re-handles `.search`: cancels "b" while it sleeps
        await model.advance(clock, by: effectDuration)
        await model.expect { $0.results = ["a", "c"] }  // "b" never completed
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func reHandlingAChildCaseThroughAWhenKeyPathCancelsOnlyThatChildCasesEffects() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.a(.start)) { $0.a.starts = 1 }
        await model.send(.a(.other))  // another case of the same child
        await model.send(.other)  // another root case
        await model.send(.b(.start)) { $0.b.starts = 1 }  // the same case of a sibling child
        await model.advance(clock, by: effectDuration)
        await model.expect {  // none of those sends cancelled a #1
            $0.a.completed = [1]
            $0.b.completed = [1]
        }

        await model.send(.a(.start)) { $0.a.starts = 2 }
        await model.send(.a(.other))
        await model.send(.other)
        await model.send(.b(.start)) { $0.b.starts = 2 }
        await model.send(.a(.start)) { $0.a.starts = 3 }  // re-handles `.a(.start)`: cancels a #2
        await model.advance(clock, by: effectDuration)
        await model.expect {
            $0.a.completed = [1, 3]  // a #2 never completed
            $0.b.completed = [1, 2]
        }
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func reHandlingAChildCaseThroughAWhenCasePathCancelsOnlyThatChildCasesEffects() async {
        let clock = EffectClock()
        let model = await TestModel(
            initialState: AutoCancelModeState.active(AutoCancelChildState()),
            feature: Feature(interactor: AutoCancelModeInteractor(clock: clock))
        )

        await model.send(.active(.start)) { $0.modify(\.active) { $0.starts = 1 } }
        await model.send(.active(.other))  // another case of the same child
        await model.send(.other)  // another root case
        await model.advance(clock, by: effectDuration)
        await model.expect { $0.modify(\.active) { $0.completed = [1] } }  // neither cancelled start #1

        await model.send(.active(.start)) { $0.modify(\.active) { $0.starts = 2 } }
        await model.send(.active(.other))
        await model.send(.other)
        await model.send(.active(.start)) { $0.modify(\.active) { $0.starts = 3 } }  // cancels start #2
        await model.advance(clock, by: effectDuration)
        await model.expect { $0.modify(\.active) { $0.completed = [1, 3] } }  // start #2 never completed
        await model.finish()
    }

    /// A parent effect performed for `.a(.start)` sits at the parent's path, `[tag(a)]`, so any
    /// action of that child cancels it, while the child's own effect sits at `[tag(a), tag(start)]`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func parentEffectForAChildActionIsCancelledByAnyActionOfThatChild() async {
        let clock = EffectClock()
        let model = await TestModel(
            initialState: AutoCancelState(),
            feature: Feature(interactor: ChildActionObservingInteractor(clock: clock))
        )

        // Left alone, both effects complete.
        await model.send(.a(.start)) { $0.a.starts = 1 }
        await model.advance(clock, by: effectDuration)
        await model.expect {
            $0.a.completed = [1]
            $0.results = ["parent effect for a.start"]
        }

        await model.send(.a(.start)) { $0.a.starts = 2 }
        await model.send(.a(.other))  // cancels the parent's effect, not the child's
        await model.advance(clock, by: effectDuration)
        await model.expect { $0.a.completed = [1, 2] }  // the second parent effect never completed
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func mergedInteractorsBothStartTheirEffectsAndReHandlingTheCaseCancelsBoth() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.go) {  // both preambles ran inside `send`, in merge order
            $0.goRuns = 1
            $0.goStarted = ["go effect 1 of run 1", "go effect 2 of run 1"]
        }
        await model.send(.go) {  // cancels both effects of run 1, then starts run 2's
            $0.goRuns = 2
            $0.goStarted += ["go effect 1 of run 2", "go effect 2 of run 2"]
        }

        await model.advance(clock, by: effectDuration)
        await model.expect { $0.goCompleted = ["go effect 1 of run 2", "go effect 2 of run 2"] }  // not run 1's
        await model.finish()
    }

    /// Current behaviour: `When` over a case path resolves the child before scoping, so an action
    /// for an inactive case returns early without visiting the child's path, and the effects the
    /// child started while it was active keep running until the case is handled again.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func childActionForAnInactiveCaseIsIgnoredAndCancelsNothing() async {
        let clock = EffectClock()
        let model = await TestModel(
            initialState: AutoCancelModeState.active(AutoCancelChildState()),
            feature: Feature(interactor: AutoCancelModeInteractor(clock: clock))
        )

        // Start #1 runs on through the deactivation, the ignored action and the reactivation, and
        // completes into the new payload.
        await model.send(.active(.start)) { $0.modify(\.active) { $0.starts = 1 } }
        await model.send(.deactivate) { $0 = .idle }
        #expect(await model.send(.active(.start)) == nil)  // ignored: starts and cancels nothing
        await model.send(.activate(starts: 10)) { $0 = .active(AutoCancelChildState(starts: 10)) }
        await model.advance(clock, by: effectDuration)
        await model.expect { $0.modify(\.active) { $0.completed = [1] } }

        // Handling the case again once it is active cancels what the child started before.
        await model.send(.active(.start)) { $0.modify(\.active) { $0.starts = 11 } }
        await model.send(.deactivate) { $0 = .idle }
        #expect(await model.send(.active(.start)) == nil)
        await model.send(.activate(starts: 20)) { $0 = .active(AutoCancelChildState(starts: 20)) }
        await model.send(.active(.start)) { $0.modify(\.active) { $0.starts = 21 } }  // cancels start #11
        await model.advance(clock, by: effectDuration)
        await model.expect { $0.modify(\.active) { $0.completed = [21] } }  // start #11 never completed
        await model.finish()
    }

    @Test
    func enumTagIsStablePerCaseAcrossPayloadsAndIndirectCases() {
        #expect(enumTag(TagProbe.leaf(1)) == enumTag(TagProbe.leaf(2)))
        #expect(enumTag(TagProbe.pair(.leaf(1), .empty)) == enumTag(TagProbe.pair(.empty, .pair(.leaf(2), .leaf(3)))))
        #expect(enumTag(TagProbe.labeled("a", [])) == enumTag(TagProbe.labeled("b", [1, 2])))

        let tags = [TagProbe.leaf(0), .pair(.empty, .empty), .labeled("", []), .empty].map { enumTag($0) }
        #expect(Set(tags).count == 4)

        #expect(enumTag(42) == -1)
        #expect(enumTag(NotAnEnum()) == -1)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func reHandlingAnIndirectCaseCancelsItsEffectsWhateverThePayload() async {
        let clock = EffectClock()
        let model = await TestModel(initialState: TreeState(), feature: Feature(interactor: TreeInteractor(clock: clock)))

        await model.send(.node(.leaf("x"), .leaf("y"))) { $0.nodes = 1 }
        await model.send(.leaf("z"))  // another case
        await model.advance(clock, by: effectDuration)
        await model.expect {  // `.leaf` cancelled nothing
            $0.completedNodes = [1]
            $0.completedLeaves = ["z"]
        }

        await model.send(.node(.leaf("x"), .leaf("y"))) { $0.nodes = 2 }
        await model.send(.leaf("w"))
        await model.send(.node(.node(.leaf("p"), .leaf("q")), .leaf("r"))) { $0.nodes = 3 }  // cancels node #2
        await model.advance(clock, by: effectDuration)
        await model.expect {
            $0.completedNodes = [1, 3]  // node #2 never completed
            $0.completedLeaves = ["z", "w"]
        }
        await model.finish()
    }
}

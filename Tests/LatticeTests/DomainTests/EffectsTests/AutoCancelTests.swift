import CasePaths
import Clocks
import Foundation
import Testing

@testable import Lattice

// MARK: - Child

@FeatureState
struct AutoCancelChildState: Equatable {
    var starts = 0
}

@CasePathable
enum AutoCancelChildAction: Equatable {
    case start
    case other
}

/// `.start` performs an effect that sleeps until cancelled and logs its cancellation synchronously.
@Interactor<AutoCancelChildState, AutoCancelChildAction>
struct AutoCancelChildInteractor {
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

// MARK: - Key-path parent

@FeatureState
struct AutoCancelState: Equatable {
    var a = AutoCancelChildState()
    var b = AutoCancelChildState()
    var results: [String] = []
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
    let log: EffectLog
    let clock: TestClock<Duration>
    let gate: EffectGate

    var body: some InteractorOf<Self> {
        Interactors.When(state: \.a, action: \.a) {
            AutoCancelChildInteractor(name: "a", log: log, clock: clock)
        }
        Interactors.When(state: \.b, action: \.b) {
            AutoCancelChildInteractor(name: "b", log: log, clock: clock)
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

/// A parent that performs its own effect when it handles the child action `.a(.start)`.
@Interactor<AutoCancelState, AutoCancelAction>
struct ChildActionObservingInteractor {
    let log: EffectLog
    let clock: TestClock<Duration>

    var body: some InteractorOf<Self> {
        Interactors.When(state: \.a, action: \.a) {
            AutoCancelChildInteractor(name: "a", log: log, clock: clock)
        }
        Interact { _, action, effects in
            if case .a(.start) = action {
                effects.perform {
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "parent effect for a.start cancelled")
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
    let log: EffectLog
    let clock: TestClock<Duration>

    var body: some InteractorOf<Self> {
        Interact { state, action, _ in
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
            AutoCancelChildInteractor(name: "active", log: log, clock: clock)
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
}

indirect enum TreeAction {
    case leaf(String)
    case node(TreeAction, TreeAction)
}

/// Every action performs an effect labelled with its root case and a running count of `.node`s.
@Interactor<TreeState, TreeAction>
struct TreeInteractor {
    let log: EffectLog
    let clock: TestClock<Duration>

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .leaf(let name):
                effects.perform {
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "leaf \(name) cancelled")
                }
            case .node:
                state.nodes += 1
                let node = state.nodes
                effects.perform {
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "node #\(node) cancelled")
                }
            }
        }
    }
}

// MARK: - Tests

/// Anonymous effects are cancelled when the enum-tag path that performed them is handled again:
/// the root action's case, then one child case per `When` hop.
@MainActor
@Suite
struct AutoCancelTests {
    private func makeViewModel(
        log: EffectLog,
        gate: EffectGate = EffectGate()
    ) -> ViewModel<Feature<AutoCancelAction, AutoCancelState>> {
        ViewModel(
            initialState: AutoCancelState(),
            feature: Feature(interactor: AutoCancelInteractor(log: log, clock: TestClock(), gate: gate))
        )
    }

    @Test
    func reHandlingAnActionCaseCancelsOnlyThatCasesPreviousEffects() async {
        let log = EffectLog()
        let gate = EffectGate()
        let viewModel = makeViewModel(log: log, gate: gate)

        let first = viewModel.sendViewEvent(.search("a"))
        #expect(viewModel.sendViewEvent(.other) == nil)  // another case: cancels nothing
        #expect(log.entries.isEmpty)
        let second = viewModel.sendViewEvent(.search("b"))
        #expect(log.entries == ["search a cancelled"])

        // Both searches resume; the cancelled one stops at its cancellation-aware suspension point.
        gate.open()
        await first?.value
        await second?.value
        #expect(viewModel.results == ["b"])
    }

    @Test
    func reHandlingAChildCaseThroughAWhenKeyPathCancelsOnlyThatChildCasesEffects() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.a(.start))
        viewModel.sendViewEvent(.a(.other))  // another case of the same child
        viewModel.sendViewEvent(.other)  // another root case
        viewModel.sendViewEvent(.b(.start))  // the same case of a sibling child
        #expect(log.entries.isEmpty)

        viewModel.sendViewEvent(.a(.start))
        #expect(log.entries == ["a start #1 cancelled"])
    }

    @Test
    func reHandlingAChildCaseThroughAWhenCasePathCancelsOnlyThatChildCasesEffects() {
        let log = EffectLog()
        let viewModel = ViewModel(
            initialState: AutoCancelModeState.active(AutoCancelChildState()),
            feature: Feature(interactor: AutoCancelModeInteractor(log: log, clock: TestClock()))
        )

        viewModel.sendViewEvent(.active(.start))
        viewModel.sendViewEvent(.active(.other))  // another case of the same child
        viewModel.sendViewEvent(.other)  // another root case
        #expect(log.entries.isEmpty)

        viewModel.sendViewEvent(.active(.start))
        #expect(log.entries == ["active start #1 cancelled"])
    }

    /// A parent effect performed for `.a(.start)` sits at the parent's path, `[tag(a)]`, so any
    /// action of that child cancels it, while the child's own effect sits at `[tag(a), tag(start)]`.
    @Test
    func parentEffectForAChildActionIsCancelledByAnyActionOfThatChild() {
        let log = EffectLog()
        let viewModel = ViewModel(
            initialState: AutoCancelState(),
            feature: Feature(interactor: ChildActionObservingInteractor(log: log, clock: TestClock()))
        )

        viewModel.sendViewEvent(.a(.start))
        viewModel.sendViewEvent(.a(.other))

        #expect(log.entries == ["parent effect for a.start cancelled"])
    }

    @Test
    func mergedInteractorsBothStartTheirEffectsAndReHandlingTheCaseCancelsBoth() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.go)
        #expect(log.entries == ["go effect 1 started", "go effect 2 started"])

        viewModel.sendViewEvent(.go)
        let cancelled = log.entries.filter { $0.hasSuffix("cancelled") }
        #expect(cancelled.sorted() == ["go effect 1 cancelled", "go effect 2 cancelled"])
        #expect(log.entries.suffix(2) == ["go effect 1 started", "go effect 2 started"])
    }

    /// Current behaviour: `When` over a case path resolves the child before scoping, so an action
    /// for an inactive case returns early without visiting the child's path, and the effects the
    /// child started while it was active keep running until the case is handled again.
    @Test
    func childActionForAnInactiveCaseIsIgnoredAndCancelsNothing() {
        let log = EffectLog()
        let viewModel = ViewModel(
            initialState: AutoCancelModeState.active(AutoCancelChildState()),
            feature: Feature(interactor: AutoCancelModeInteractor(log: log, clock: TestClock()))
        )

        viewModel.sendViewEvent(.active(.start))
        viewModel.sendViewEvent(.deactivate)
        #expect(viewModel.sendViewEvent(.active(.start)) == nil)
        #expect(log.entries.isEmpty)

        viewModel.sendViewEvent(.activate(starts: 10))
        viewModel.sendViewEvent(.active(.start))
        #expect(log.entries == ["active start #1 cancelled"])
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

    @Test
    func reHandlingAnIndirectCaseCancelsItsEffectsWhateverThePayload() {
        let log = EffectLog()
        let viewModel = ViewModel(
            initialState: TreeState(),
            feature: Feature(interactor: TreeInteractor(log: log, clock: TestClock()))
        )

        viewModel.sendViewEvent(.node(.leaf("x"), .leaf("y")))
        viewModel.sendViewEvent(.leaf("z"))  // another case
        #expect(log.entries.isEmpty)

        viewModel.sendViewEvent(.node(.node(.leaf("p"), .leaf("q")), .leaf("r")))
        #expect(log.entries == ["node #1 cancelled"])
    }
}

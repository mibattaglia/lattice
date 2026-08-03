// Plan 04 test suite 2 (additive): `When` builds the scoped handle with the right lenses and
// component on the imperative-effect pathway. The full dismissed-mid-request drop/cancel
// contract lives in the plan 03 suites; here we assert routing, embedding, and that a child
// effect's `modify` lands in the parent's scoped slice (plus watcher registration end-to-end).

import CasePaths
import Foundation
import Testing

@testable import Lattice

// MARK: - Fixtures

private struct RouteChildState: Equatable, Sendable {
    var value = 0
}

private enum RouteChildAction: Sendable {
    case bump
    case fetch
    case fetchGated
}

/// The child feature: synchronous mutation plus an effect that re-enters via `modify`.
/// `@unchecked Sendable` is transitional: `When`'s `Child: Interactor & Sendable` gate is
/// removed by plan 06; the gate is only ever touched on the MainActor.
private struct RouteChildInteractor: Interactor, @unchecked Sendable {
    let gate: Gate?

    init(gate: Gate? = nil) {
        self.gate = gate
    }

    var body: some Interactor<RouteChildState, RouteChildAction> {
        Interact {
            (
                state: inout RouteChildState,
                action: RouteChildAction,
                effects: Effects<RouteChildState, RouteChildAction>
            ) in
            switch action {
            case .bump:
                state.value += 1
            case .fetch:
                effects.perform { effectState in
                    try effectState.modify { $0.value = 42 }
                }
            case .fetchGated:
                effects.perform { [gate = self.gate] effectState in
                    await gate?.wait()
                    try effectState.modify { $0.value = 99 }
                }
            }
        }
    }
}

private struct RouteParentState: Sendable {
    var child = RouteChildState()
    var parentValue = 0
}

@CasePathable
private enum RouteParentAction: Sendable {
    case child(RouteChildAction)
    case parentBump
}

@CasePathable
private enum RouteEnumState: Sendable {
    case loaded(RouteChildState)
    case idle
}

@CasePathable
private enum RouteEnumAction: Sendable {
    case loaded(RouteChildAction)
    case reset
}

@MainActor
private func makeCore<State: Sendable, Action: Sendable, Root: Interactor>(
    initial: State,
    root: Root
) -> LatticeCore<State, Action> where Root.DomainState == State, Root.Action == Action {
    let core = LatticeCore<State, Action>(initialState: initial, isolation: MainActor.shared)
    let effects: Effects<State, Action> = _makeEffectsHandles(
        core: core,
        lens: .identity,
        path: GraphPath()
    )
    core.mount(interact: { state, action in
        root.interact(state: &state, action: action, effects: effects)
    })
    return core
}

// MARK: - Tests

@Suite
@MainActor
struct WhenEffectsRoutingTests {

    @Test
    func childActionIsExtractedAndForwarded() throws {
        let root = Interactors.When<RouteParentState, RouteParentAction, _>(
            state: \.child,
            action: \.child
        ) {
            RouteChildInteractor()
        }
        let core = makeCore(initial: RouteParentState(), root: root)

        try core.send(.child(.bump))

        #expect(core.currentState.child.value == 1)
        #expect(core.currentState.parentValue == 0)
    }

    @Test
    func nonMatchingParentActionIsANoOpForTheChild() throws {
        let root = Interactors.When<RouteParentState, RouteParentAction, _>(
            state: \.child,
            action: \.child
        ) {
            RouteChildInteractor()
        }
        let core = makeCore(initial: RouteParentState(), root: root)

        try core.send(.parentBump)

        #expect(core.currentState.child.value == 0)
    }

    @Test
    func absentCaseDoesNotInvokeTheChild() throws {
        let root = Interactors.When<RouteEnumState, RouteEnumAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            RouteChildInteractor()
        }
        let core = makeCore(initial: RouteEnumState.idle, root: root)

        try core.send(.loaded(.bump))

        guard case .idle = core.currentState else {
            Issue.record("Expected state to remain .idle")
            return
        }
    }

    @Test
    func childSynchronousMutationEmbedsBackIntoParentState() throws {
        let root = Interactors.When<RouteEnumState, RouteEnumAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            RouteChildInteractor()
        }
        let core = makeCore(initial: RouteEnumState.loaded(RouteChildState()), root: root)

        try core.send(.loaded(.bump))

        guard case .loaded(let child) = core.currentState else {
            Issue.record("Expected state to remain .loaded")
            return
        }
        #expect(child.value == 1)
    }

    @Test
    func childEffectModifyLandsInTheParentScopedSlice() throws {
        let root = Interactors.When<RouteParentState, RouteParentAction, _>(
            state: \.child,
            action: \.child
        ) {
            RouteChildInteractor()
        }
        let core = makeCore(initial: RouteParentState(), root: root)

        // The effect body runs synchronously up to its first suspension; a straight-line
        // `modify` lands before `send` returns.
        try core.send(.child(.fetch))

        #expect(core.currentState.child.value == 42)
        #expect(core.currentState.parentValue == 0)
    }

    @Test
    func leavingTheChildCaseCancelsItsEffectAndDropsTheStragglerModify() async throws {
        let gate = Gate()
        let root = collectRoot(gate: gate)
        let core = makeCore(initial: RouteEnumState.loaded(RouteChildState()), root: root)

        // Launch a gated child effect, then leave the case before it resumes. The presence
        // watcher registered by `When`'s scoped handle cancels the child's bucket.
        let task = try core.send(.loaded(.fetchGated))
        try core.send(.reset)
        gate.open()
        await task?.value

        guard case .idle = core.currentState else {
            Issue.record("Expected the straggler modify to be dropped after case departure")
            return
        }
    }
}

/// When + parent handler, composed the way a feature body would be.
private func collectRoot(gate: Gate) -> some Interactor<RouteEnumState, RouteEnumAction> {
    Interactors.CollectInteractors<RouteEnumState, RouteEnumAction, _> {
        Interactors.When<RouteEnumState, RouteEnumAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            RouteChildInteractor(gate: gate)
        }
        Interact {
            (state: inout RouteEnumState, action: RouteEnumAction, _: Effects<RouteEnumState, RouteEnumAction>) in
            if case .reset = action {
                state = .idle
            }
        }
    }
}

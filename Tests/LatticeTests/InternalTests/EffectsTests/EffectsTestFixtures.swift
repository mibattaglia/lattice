// Shared fixtures for the effects-handle tests (plan 03). Everything here is deliberately
// **non-Sendable** — that absence is itself part of the assertion (plan 03 test plan).

import CasePaths
import Foundation

@testable import Lattice

// MARK: - Root fixture (handle, cancellation, EffectID tests)

struct HandleState {
    var n = 0
    var text = ""
}

/// A closure-carrying action: each send routes to the closure, which receives the `inout`
/// state and the node's update-phase `Effects` handle (as plan 04's `Interact` will).
struct HandleAction {
    let run: (inout HandleState, Effects<HandleState, HandleAction>) -> Void

    init(_ run: @escaping (inout HandleState, Effects<HandleState, HandleAction>) -> Void) {
        self.run = run
    }
}

typealias HandleCore = LatticeCore<HandleState, HandleAction>

/// Builds a mounted core plus its root handle pair (identity lens, root path).
@MainActor
func makeHandleCore(
    initial: HandleState = HandleState(),
    onCommit: ((HandleState, HandleState) -> Void)? = nil
) -> (core: HandleCore, effects: Effects<HandleState, HandleAction>) {
    let core = HandleCore(initialState: initial, isolation: MainActor.shared)
    let effects = _makeEffectsHandles(core: core, lens: .identity, path: GraphPath())
    core.mount(
        interact: { state, action in
            action.run(&state, effects)
        },
        onCommit: onCommit
    )
    return (core, effects)
}

// MARK: - Scoped fixture (the navigation-dismissed-mid-request contract)

struct ScopedChildState: Equatable {
    var value = 0
}

enum ScopedDestination {
    case detail(ScopedChildState)
    case other
}

struct ScopedParentState {
    var counter = 0
    var destination: ScopedDestination?
    var direct = ScopedChildState()
}

enum ScopedChildAction {
    case ping
}

enum ScopedParentAction {
    /// Parent-level closure action; receives the core so tests can drive updates freely.
    case run((inout ScopedParentState) -> Void)
    /// A child action embedded into the parent space (what `effectState.send` routes through).
    case child(ScopedChildAction)
}

typealias ScopedCore = LatticeCore<ScopedParentState, ScopedParentAction>
typealias ScopedLensRoot = _ScopeLens<
    ScopedParentState, ScopedParentAction, ScopedParentState, ScopedParentAction
>

let scopedActionIdentity = AnyCasePath<ScopedParentAction, ScopedParentAction>(
    embed: { $0 },
    extract: { $0 }
)

let scopedChildActionCase = AnyCasePath<ScopedParentAction, ScopedChildAction>(
    embed: { .child($0) },
    extract: {
        if case .child(let action) = $0 { return action }
        return nil
    }
)

let scopedDetailCase = AnyCasePath<ScopedDestination?, ScopedChildState>(
    embed: { .detail($0) },
    extract: {
        if case .detail(let child)? = $0 { return child }
        return nil
    }
)

/// The enum-scoped child's structural path: `\.destination` + the `.detail` case tag.
@MainActor
let scopedChildPath = GraphPath()
    .appending(\ScopedParentState.destination)
    .appending(id: "detail")

/// The enum-scoped child's lens: `\.destination` key path, then the `.detail` case.
@MainActor
let scopedChildLens = ScopedLensRoot.identity
    .appending(state: \ScopedParentState.destination, action: scopedActionIdentity)
    .appending(state: scopedDetailCase, action: scopedChildActionCase)

/// Builds a mounted scoped-fixture core with the enum child's presence watcher registered,
/// recording every child action the tree routes.
@MainActor
func makeScopedCore(
    initial: ScopedParentState = ScopedParentState(),
    onCommit: ((ScopedParentState, ScopedParentState) -> Void)? = nil,
    onChildAction: ((ScopedChildAction) -> Void)? = nil
) -> ScopedCore {
    let core = ScopedCore(initialState: initial, isolation: MainActor.shared)
    core.mount(
        interact: { state, action in
            switch action {
            case .run(let run):
                run(&state)
            case .child(let childAction):
                onChildAction?(childAction)
            }
        },
        onCommit: onCommit
    )
    core.registerPresenceWatcher(path: scopedChildPath) {
        scopedChildLens.extract($0) != nil
    }
    return core
}

// MARK: - Drop-hook recording

// (`Recorder` and `Gate` are reused from `CoreTestFixtures.swift` — same test target.)

#if DEBUG
    /// Records `_EffectsDiagnostics.onDroppedReentry` fires for one test, restoring the hook
    /// on deinit.
    final class DropHookRecorder {
        private(set) var drops: [(kind: _EffectsDiagnostics.DroppedReentryKind, path: GraphPath)] = []

        init() {
            _EffectsDiagnostics.onDroppedReentry = { [weak self] kind, path, _, _ in
                self?.drops.append((kind, path))
            }
        }

        deinit {
            _EffectsDiagnostics.onDroppedReentry = nil
        }
    }
#endif

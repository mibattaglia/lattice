// Shared fixtures for the LatticeCore isolation tests (plan 02 §8). The state is
// deliberately **non-Sendable** (`NonSendableBox` is a plain class) to prove the runtime
// compiles and runs without any `Sendable` requirement.

import Foundation

@testable import Lattice

/// Namespace suite: groups every core suite under one `CoreTests` prefix so the plan's gate
/// (`swift test --filter CoreTests`) selects exactly these.
enum CoreTests {}

// MARK: - Non-Sendable domain state

final class NonSendableBox {
    var value = 0
}

struct CoreChild {
    var m = 0
}

struct S {
    var n = 0
    var child: CoreChild?
    var box = NonSendableBox()
}

// MARK: - Action

/// A closure-carrying action: each send routes to the closure, which receives the `inout`
/// state and the core (for `launchEffect` during the update phase).
struct SAction {
    let run: (inout S, LatticeCore<S, SAction>) -> Void

    init(_ run: @escaping (inout S, LatticeCore<S, SAction>) -> Void) {
        self.run = run
    }
}

typealias TestCore = LatticeCore<S, SAction>

// MARK: - Helpers

/// Builds a core mounted with the closure-routing interact and an optional commit hook.
@MainActor
func makeCore(
    initial: S = S(),
    onCommit: ((S, S) -> Void)? = nil,
    onEffectLaunched: ((TaskKey, Task<Void, Never>) -> Void)? = nil
) -> TestCore {
    let core = TestCore(initialState: initial, isolation: MainActor.shared)
    core.mount(
        interact: { [unowned core] state, action in
            action.run(&state, core)
        },
        onCommit: onCommit,
        onEffectLaunched: onEffectLaunched
    )
    return core
}

/// Deterministic effect-slot identity for tests that call `launchEffect` directly (plan 3's
/// `perform` supplies real `#fileID`/`#line`/`#column` defaults).
func loc(_ line: UInt) -> EffectLocation {
    .callSite(fileID: "CoreTests/Fixture.swift", line: line, column: 1)
}

// MARK: - Recording (non-Sendable by design)

/// Event recorder captured by effect closures. A plain class: all touches happen on the
/// MainActor at runtime (in-domain effect start), so no synchronization is needed — which is
/// exactly the confinement property under test.
final class Recorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

/// A resumable suspension point for holding effects open until the test releases them.
/// MainActor-confined by usage, like everything else here.
final class Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in continuations {
            continuation.resume()
        }
        continuations.removeAll()
    }
}

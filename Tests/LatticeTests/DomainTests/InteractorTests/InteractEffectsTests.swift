// `Interact` handler-overload resolution, and the debounce-by-replacement idiom
// expressed through a real interactor tree.

import Clocks
import Foundation
import Testing

@testable import Lattice

// MARK: - Fixtures

private struct OverloadState: Sendable {
    var n = 0
    var query = ""
}

private enum OverloadAction: Sendable {
    case bump
    case fetch
    case queryChanged(String)
}

@MainActor
private func makeCore<Root: Interactor<OverloadState, OverloadAction>>(
    root: Root
) -> LatticeCore<OverloadState, OverloadAction> {
    let core = LatticeCore<OverloadState, OverloadAction>(
        initialState: OverloadState(),
        isolation: MainActor.shared
    )
    let effects: Effects<OverloadState, OverloadAction> = _makeEffectsHandles(
        core: core,
        lens: .identity,
        path: GraphPath()
    )
    core.mount(interact: { state, action in
        root.interact(state: &state, action: action, effects: effects)
    })
    return core
}

// MARK: - Overload resolution

@Suite
@MainActor
struct InteractEffectsOverloadTests {

    @Test
    func ignoringTheEffectsHandleWithAWildcardResolves() {
        let interact = Interact {
            (state: inout OverloadState, action: OverloadAction, _: Effects<OverloadState, OverloadAction>) in
            if case .bump = action {
                state.n += 1
            }
        }

        var state = OverloadState()
        interact.interact(
            state: &state,
            action: .bump,
            effects: _detachedEffectsHandle(path: GraphPath())
        )
        #expect(state.n == 1)
    }

    @Test
    func twoArgVoidConvenienceResolvesAndNeverObservesAHandle() {
        // The two-argument `Void` convenience: pure-mutation leaves drop the handle entirely.
        let interact = Interact { (state: inout OverloadState, action: OverloadAction) in
            if case .bump = action {
                state.n += 1
            }
        }

        var state = OverloadState()
        interact.interact(
            state: &state,
            action: .bump,
            effects: _detachedEffectsHandle(path: GraphPath())
        )
        #expect(state.n == 1)
    }

    @Test
    func threeArgHandlerResolvesAndLaunchesEffects() throws {
        let root = Interact {
            (
                state: inout OverloadState,
                action: OverloadAction,
                effects: Effects<OverloadState, OverloadAction>
            ) in
            if case .fetch = action {
                state.n += 1
                effects.perform { effectState in
                    try effectState.modify { $0.n = 42 }
                }
            }
        }
        let core = makeCore(root: root)

        try core.send(.fetch)

        #expect(core.currentState.n == 42)
    }
}

// MARK: - Debounce idiom (task replacement + leading sleep)

@Suite
@MainActor
struct InteractorDebounceIdiomTests {

    /// Search-as-you-type expressed with per-call-site auto-replacement: rapid re-sends of
    /// the same action reach one `perform` line, so only the last effect survives the quiet
    /// period, while the state mutation is immediate on every send.
    @Test
    func rapidResendsRunOnlyTheLastEffectWhileStateMutatesImmediately() async throws {
        let recorder = Recorder()
        let clock = TestClock()

        let root = Interact {
            (
                state: inout OverloadState,
                action: OverloadAction,
                effects: Effects<OverloadState, OverloadAction>
            ) in
            if case .queryChanged(let query) = action {
                state.query = query  // state mutation is immediate
                effects.perform { effectState in
                    // The previous keystroke's task is cancelled (same `perform` line).
                    try await clock.sleep(for: .milliseconds(300))
                    recorder.record("search \(effectState.state.query)")
                }
            }
        }
        let core = makeCore(root: root)

        _ = try core.send(.queryChanged("s"))
        #expect(core.currentState.query == "s")
        _ = try core.send(.queryChanged("sw"))
        #expect(core.currentState.query == "sw")
        let last = try core.send(.queryChanged("swi"))
        #expect(core.currentState.query == "swi")

        await clock.advance(by: .milliseconds(300))
        await last?.value

        // Exactly one search executed, for the final query.
        #expect(recorder.events == ["search swi"])
    }
}

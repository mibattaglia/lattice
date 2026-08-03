---
name: lattice-testing
description: Test Lattice features with snapshot-diff TestViewModel assertions and TestClock.
license: MIT
metadata:
  short-description: Testing patterns for Lattice.
---

# Lattice Testing

## Goal

Write deterministic, exhaustive tests for Lattice features with the snapshot-diff testing
model: every state change — synchronous mutations from `send` and asynchronous re-entries from
`effectState.modify` — is asserted as a diff against the previous state.

## Core tools

- `TestViewModel<DomainState, Action>` — hosts the feature with a test core; fails the test
  for any unasserted state change or unasserted received action. Requires
  `DomainState: Equatable` (snapshot diffs compare with `==`).
- `send(_:changes:)` — dispatch an action, assert the synchronous update-phase mutation.
- `expect(timeout:changes:)` — assert the next state change committed by an effect's
  `effectState.modify`.
- `receive(_:timeout:changes:)` — assert an action re-entered via `effectState.send` (rare;
  most effects use `modify` and are asserted with `expect`).
- `TestClock` from `Clocks` — drive `clock.sleep`-based debounce windows deterministically.
- `dismount()` — tear the feature down, cancelling in-flight effects, and fail on unasserted
  commits.

## Snapshot-diff feature test

```swift
import Clocks
import Lattice
import Testing

@Suite
@MainActor
struct SearchInteractorTests {

    @Test
    func debouncedSearch() async throws {
        let clock = TestClock()
        let model = TestViewModel(
            initialDomainState: SearchState(),
            interactor: SearchInteractor(searchClient: SearchClientStub(), clock: clock)
        )

        // Update phase: synchronous mutations asserted immediately.
        await model.send(.queryChanged("latt")) {
            $0.query = "latt"
            $0.isLoading = true
        }

        // Typing again replaces the in-flight task (debounce restart) — same sync assert.
        await model.send(.queryChanged("lattice")) {
            $0.query = "lattice"
        }

        // Cross the debounce window; only the second search runs.
        await clock.advance(by: .milliseconds(300))

        // Effect re-entry: assert the `effectState.modify` diff.
        await model.expect {
            $0.isLoading = false
            $0.results = ["Lattice"]
        }
    }
}
```

## Rules

- Assert **every** state change: an unasserted `modify` from an effect fails the test at the
  end of scope (exhaustive by default). `skipPendingCommits()` is the explicit escape hatch,
  and `exhaustivity = .off()` relaxes enforcement for tests that care about a subset.
- Diffs assert the state value — `@Domain` members included; only *views* are fenced off from
  domain members. View output is asserted by reading the projection
  (`#expect(model.projection.statusText == "1 result")`) — no ViewState fixtures, no reducer
  unit tests.
- `send` asserts only the update phase. Effect output is asserted with `expect(changes:)` in
  commit order. The optional `timeout:` parameter comes before the `changes:` closure.
- `receive(\.someAction) { … }` exists only for effects that re-enter with `effectState.send`;
  if your feature never calls `effectState.send`, you never call `receive`.
- Effects run synchronously up to their first suspension point, so commits made before an
  effect first suspends are already pending when `send` returns — `expect` for those succeeds
  without waiting.
- Time-based effects: inject `any Clock<Duration>` and pass `TestClock`; advance it past the
  window, then `expect` the re-entry. Never sleep in tests.
- Dismissal contract: to test navigation-dismissed-mid-request, `send` the action that leaves
  the child's case, then verify no further diffs arrive — the child's straggler `modify` is
  dropped and its tasks are cancelled.
- Prefer an explicit `await model.dismount()` at test end over relying on the deinit backstop,
  so failures land at a useful source location.
- Non-Sendable fixtures are the norm: stub clients can be simple classes; nothing in a test
  needs `Sendable` or `@unchecked`.

## References
- See `resources/async-and-time.md` for async sequencing and time control.

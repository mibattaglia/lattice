---
name: lattice-testing
description: Test Lattice features with TestViewModel, TestEventTask, exhaustivity, and TestClock.
license: MIT
metadata:
  short-description: Testing patterns for Lattice.
---

# Lattice Testing

## Goal

Write deterministic tests for Lattice features with the current step-wise testing model. Prefer `TestViewModel` for feature behavior, and use production `ViewModel` tests only when SwiftUI-facing wiring needs coverage.

## Core tools

- `TestViewModel<F>` for state-first, step-wise feature tests. `model.state` is the raw state, `@Domain` members included.
- `TestEventTask` for root-send-scope completion and cancellation.
- `TestClock` from `Clocks` for debounce and time-based behavior.
- `exhaustivity`, `skipReceivedActions()`, and `skipInFlightEffects()` for buffered receives and long-lived work.

## Step-wise feature tests

```swift
import Clocks
import Lattice
import Testing

@Suite
@MainActor
final class CounterInteractorTests {

    @Test
    func increment() async {
        let model = TestViewModel(
            initialState: CounterState(count: 0),
            feature: Feature(interactor: CounterInteractor())
        )

        let task = await model.send(.increment) {
            $0.count = 1
        }

        await task.finish()
    }
}
```

These assertion APIs are non-throwing: use `send`, `receive`, `finish`, and
`TestEventTask.finish()` directly without `try`.

## State equality

Assertions compare states with the feature's `areStatesEqual`:

- `Feature(interactor:)` supplies `==` for an `Equatable` state.
- For a state that is not `Equatable`, or a comparison that ignores generated values such as IDs, build the feature with `Feature(interactor:areStatesEqual:)`.
- `TestViewModel(initialState:feature:areStatesEqual:)` covers a feature without an equality; the feature's own equality takes precedence over it.
- With no equality at all, `TestViewModel` reports an issue at `init` and every state assertion fails.

```swift
let model = TestViewModel(
    initialState: TodosState(),
    feature: Feature(
        interactor: TodosInteractor(clock: clock, debounceDuration: .milliseconds(300)),
        areStatesEqual: todosStatesAreEqualIgnoringIDs
    )
)
```

## Async emission output

```swift
@Test
@MainActor
func asyncIncrement() async {
    let model = TestViewModel(
        initialState: CounterState(count: 0),
        feature: Feature(interactor: AsyncCounterInteractor())
    )

    let task = await model.send(.asyncIncrement)

    await model.receive(.increment) {
        $0.count = 1
    }

    await task.finish()
}
```

Use `receive(...)` to commit the next buffered emitted action.
If `Action` is `CasePathable`, prefer `receive(\.loaded)` for case-based assertions.

## Time-based behavior

Use `TestClock` when effects depend on time (debounce/delay/retry windows).
Assert the synchronous mutation first, advance the clock, then `receive(...)` the emitted action and `finish()` the send scope.

## Buffered work semantics

- `send` asserts only the immediately visible state mutation.
- `receive(...)` advances through buffered emission output one step at a time.
- `TestEventTask.finish(timeout:)` waits for root-scope quiescence only; it does not drain buffered receives.
- `skipReceivedActions()` advances visible state past already buffered receives when a test intentionally skips step-wise assertions.
- `skipInFlightEffects()` cancels and settles currently running emission work when a test needs to move past long-lived observations or performs.
- `exhaustivity` is on by default and enforces explicit handling of buffered receives before later assertions.

## Production ViewModel tests

Only test production `ViewModel` behavior when you need to validate computed presentation members, observation, or event wiring. Reads go through the `ViewState` projection, exactly as in a view.

```swift
@Test func countTextFollowsTheCount() async {
    let feature = Feature(interactor: CounterInteractor())
    let viewModel = ViewModel(
        initialState: CounterState(count: 0),
        feature: feature
    )

    await viewModel.sendViewEvent(.increment).finish()
    #expect(viewModel.countText == "1")
}
```

## Tips

- Prefer `TestViewModel` for feature behavior and reserve production `ViewModel` tests for presentation-member, observation and wiring coverage.
- Keep assertions local to `send` and `receive` blocks so the test documents the intended state transition at each step.
- Import `Clocks` anywhere you use `TestClock`.
- Use `task.cancel()` or `skipInFlightEffects()` for intentionally unbounded emission work.

## References
- See `resources/async-and-time.md` for async sequencing and time control.

---
name: lattice-testing
description: Test Lattice interactors, emissions, and view models with InteractorTestHarness and TestClock.
license: MIT
metadata:
  short-description: Testing patterns for Lattice.
---

# Lattice Testing

## Goal

Write deterministic tests for Lattice features using the provided testing helpers. Prefer testing interactors directly, and use `ViewModel` tests only when UI wiring needs coverage.

## Core tools

- `InteractorTestHarness` for testing interactors and emissions.
- `AsyncStreamRecorder` for observing streams in tests.
- `TestClock` for time control in debounced or delayed effects.
- `EventTask.finish()` for awaiting all effects spawned by a send.

## Interactor tests

```swift
@Suite
@MainActor
final class CounterInteractorTests {

    @Test func increment() throws {
        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: CounterInteractor()
        )

        harness.send(.increment, .increment)

        try harness.assertStates([
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
        ])
    }
}
```

## Async actions

```swift
@Test func asyncIncrement() async throws {
    let harness = InteractorTestHarness(
        initialState: AsyncCounterInteractor.State(count: 0),
        interactor: AsyncCounterInteractor()
    )

    await harness.send(.asyncIncrement).finish()
    try harness.assertLatestState(.init(count: 1))
}
```

## Time-based behavior

Use `TestClock` when effects depend on time (debounce/delay/retry windows).
At the interactor level, assert both immediate state transitions and post-time-window effect outcomes.

## ViewModel tests

Only test ViewModel behavior when you need to validate state mapping or event wiring.

```swift
@Test func viewStateMapping() async throws {
    let feature = Feature(
        interactor: CounterInteractor(),
        reducer: CounterViewStateReducer()
    )
    let viewModel = ViewModel(
        initialDomainState: CounterState(count: 0),
        feature: feature
    )

    await viewModel.sendViewEvent(.increment).finish()
    #expect(viewModel.viewState.count == 1)
}
```

## Tips

- Prefer `assertStates` for full history and `assertLatestState` for targeted checks.
- Use `assertActions` to validate action history including effect-emitted actions.
- Use `AsyncStreamRecorder.waitForNextEmission(timeout:)` for stepwise stream assertions.
- Cancel long-running recorders with `cancel()` / `cancelAsync()` in teardown paths.

## References
- See `resources/async-and-time.md` for async sequencing and time control.

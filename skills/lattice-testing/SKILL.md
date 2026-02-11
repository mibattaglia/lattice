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

## TestClock for time-based behavior

```swift
@Test func debounce() async throws {
    let clock = TestClock()
    let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)

    let values = AsyncStreamRecorder<Int>()
    Task { for await value in debouncer.stream { await values.append(value) } }

    await debouncer.send(1)
    await clock.advance(by: .milliseconds(299))
    await debouncer.send(2)
    await clock.advance(by: .milliseconds(300))

    try await values.assertValues([2])
}
```

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
- If you need to inspect emitted actions from `.perform` or `.observe`, wrap streams with `AsyncStreamRecorder`.

## References
- See `resources/async-and-time.md` for async sequencing and time control.

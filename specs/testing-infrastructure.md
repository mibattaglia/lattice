> **Historical (pre-1.0):** describes the `Emission`/`ViewStateReducer`-era runtime removed in
> the 1.0 Sendable-removal rework; see `specs/sendable-removal/` for the current design.

# Testing Infrastructure

Lattice's testing model is built around `TestViewModel`, which mirrors production execution but makes emitted actions explicit and step-wise. The goal is deterministic feature testing without having to drive SwiftUI directly.

Key source files:

- [TestViewModel.swift](../Sources/Lattice/Testing/TestViewModel/TestViewModel.swift)
- [TestEventTask.swift](../Sources/Lattice/Testing/TestViewModel/TestEventTask.swift)
- [Exhaustivity.swift](../Sources/Lattice/Testing/TestViewModel/Exhaustivity.swift)
- [TestFailure.swift](../Sources/Lattice/Testing/TestViewModel/TestFailure.swift)
- [TestViewModelSendTests.swift](../Tests/LatticeTests/TestingInfrastructureTests/TestViewModelSendTests.swift)
- [TestViewModelExhaustivityTests.swift](../Tests/LatticeTests/TestingInfrastructureTests/TestViewModelExhaustivityTests.swift)
- [TestViewModelWaitingTests.swift](../Tests/LatticeTests/TestingInfrastructureTests/TestViewModelWaitingTests.swift)

## Main Tools

- `TestViewModel<F>`
- `TestEventTask`
- `Exhaustivity`
- `skipReceivedActions()`
- `skipInFlightEffects()`
- `TestClock` for time-controlled effect logic

## TestViewModel State Model

`TestViewModel` is domain-state first.

It tracks three different notions of state:

- `domainState`: the most recently asserted or committed visible state
- `assertedState`: the baseline used for the next assertion
- `latestState`: the internal state after fully reducing sent and emitted actions

That distinction is why emitted work can be processed internally before the test chooses to make it visible with `receive(...)`.

## `send(...)`

`send(...)` models the immediate effects of a root action.

It does the following:

1. Verifies exhaustivity rules.
2. Creates a root send scope.
3. Buffers the sent action and drains execution.
4. Waits for effect startup for that root scope.
5. Asserts the immediately visible domain-state mutation.
6. Returns a `TestEventTask` for that root scope.

Important consequence:

- Immediate cancellation after `send(...)` is reliable because the helper waits for effect startup before returning.

## Buffered Receives

When an emitted action is processed in tests:

- the interactor still runs immediately
- resulting state still updates `latestState`
- spawned child effects can still start immediately
- but the transition is stored in `pendingReceives` instead of being applied to visible `domainState`

`receive(...)` does not re-run the interactor. It commits a transition that has already happened internally.

## `receive(...)`

`receive(...)` advances visible state by consuming buffered emitted actions.

Overloads support:

- exact action matching
- predicate matching
- case-path matching

Behavior depends on exhaustivity mode:

- `Exhaustivity.on`: the next buffered action must match
- `Exhaustivity.off`: earlier buffered actions may be skipped until a later matching action is found

## Exhaustivity

Exhaustivity defaults to `.on`.

With `.on`:

- you must handle pending receives before sending another action
- `finish()` fails if pending receives remain

With `.off`:

- a later `send` can auto-skip already buffered receives
- `receive(...)` can skip earlier buffered actions in search of a later match

`skipReceivedActions()` is the explicit escape hatch when a test wants to acknowledge buffered work without asserting every intermediate step.

## `skipReceivedActions()`

`skipReceivedActions()` advances visible state to the last buffered resulting state and clears the queue.

It does not:

- replay individual receives
- assert intermediate states
- cancel effects

Use it for intentionally non-exhaustive tests.

## `skipInFlightEffects()`

`skipInFlightEffects()` cancels all currently tracked in-flight effects on the model and waits for them to settle.

It does not consume already buffered receives. Those still need to be received or skipped separately.

This is the model-wide escape hatch. `TestEventTask.cancel()` is the root-scope-local version.

## `TestEventTask`

`TestEventTask` belongs to one root send scope started by `send(...)`.

- `finish()` waits for that scope to become quiescent
- `cancel()` cancels that scope and waits for cancellation to settle
- `hasEffects` reports whether the root send started effect work

Crucially, `TestEventTask.finish()` does not drain buffered receives.

That means a task can finish successfully while `domainState` has not yet advanced through emitted actions that are still sitting in `pendingReceives`.

## `finish()` On TestViewModel

`TestViewModel.finish()` is broader than `TestEventTask.finish()`.

It:

1. Fails immediately if pending receives already exist.
2. Waits for all in-flight effects on the model.
3. Fails again if waiting produced new pending receives.

This is a model-wide quiescence check, not a receive drain.

## Time Control

Timeouts in the testing helpers use `ContinuousClock`.

That means:

- `receive(timeout:)`
- `finish(timeout:)`
- `TestEventTask.finish(timeout:)`

are wall-clock waits, not `TestClock` waits.

Deterministic time control comes from injecting clocks into the feature logic itself, such as:

- debounce helpers
- delayed `.perform` work
- interactors that accept a clock dependency

## Debounce Testing

There are two relevant layers:

- `Debouncer` is the low-level primitive that accepts an injected clock and distinguishes executed work from superseded work.
- `Emission.debounce(using:)` and `Interactors.Debounce` are the public runtime paths that use that primitive.

Tests for these behaviors live under:

- [EmissionDebounceTests.swift](../Tests/LatticeTests/DomainTests/EmissionDebounceTests.swift)
- [Interactors+DebounceTests.swift](../Tests/LatticeTests/DomainTests/InteractorTests/InteractorsTests/Interactors+DebounceTests.swift)
- [DebouncerTests.swift](../Tests/LatticeTests/DomainTests/InteractorTests/InteractorsTests/DebouncerTests.swift)

## Failure Reporting

Assertions are issue-reporting based rather than throwing-based.

`TestFailure` builds structured error messages for cases such as:

- unexpected received action
- missing action before timeout
- state mutation mismatch
- unhandled buffered receives
- in-flight effects that did not finish

Caller attribution is part of the design, so failures point back to the test site rather than only to the helper implementation.

## Current Caveats

- Root-scope quiescence tracks buffered action execution and in-flight effects, not pending receives.
- Emitted actions can start child effects before the test calls `receive(...)`.
- `Exhaustivity.off(showSkippedAssertions:)` currently exposes a `showSkippedAssertions` associated value that does not appear to be consumed elsewhere in the implementation.

## Related Specs

- [ViewModel Event Loop And Emission Handling](./view-model-event-loop-and-emission-handling.md)
- [Interactors](./interactors.md)

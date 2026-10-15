---
name: lattice-testing
description: Test Lattice features with TestModel and TestViewModel, exhaustivity, and a test-local gate clock.
license: MIT
metadata:
  short-description: Testing patterns for Lattice.
---

# Lattice Testing

## Goal

Write deterministic, exhaustive tests for Lattice features. A test shell runs the feature's core exactly as production does: effects start on the shell's isolation and run until their first suspension before `send` returns. The shell records every commit made outside the action under test, whether an action an effect sent or a modification an effect made, until an assertion describes it. Prefer `TestModel`; use `TestViewModel` for main-actor-isolated interactors, and production `ViewModel` tests only when SwiftUI-facing wiring needs coverage.

## Core tools

- `TestModel<F>`: an actor on its own executor, the primary test shell (iOS 26, macOS 26, watchOS 26). Its `init` and `send` are `async`.
- `TestViewModel<F>`: a `@MainActor` class with a synchronous `init` and `send`, for main-actor-isolated interactors and tests that must run on the main actor.
- `send(_:assert:)` sends an action, asserts the resulting state, and returns the `Task<Void, Never>?` for the effects the action started.
- `expect { … }` asserts the modifications effects made, which is how effects deliver their results.
- `receive(…)` waits for an action an effect sent, and asserts it.
- `finish()` waits for every effect, then fails on what was never asserted.
- `skipReceived(strict:)`, `skipInFlightEffects(strict:)` and `Exhaustivity` (`.on`, `.off(showSkippedAssertions:)`).
- A test-local gate clock for time. None ships with Lattice: copy an example package's `GateClock.swift` from the Lattice repository, such as `ExampleProject/SearchExamplePackage/Tests/SearchExampleTests/GateClock.swift`, into your test target. The reference copy in `Tests/LatticeTests/Support/GateClock.swift` has a log hook that needs that folder's `EffectLog.swift`, so it does not compile on its own.

## Writing a TestModel test

The feature under test delivers its result with `effects.modify` and clears a flag in a `defer`:

```swift
@Interactor<ProfileState, ProfileAction>
struct ProfileInteractor {
    @EffectID var load
    let client: ProfileClient

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .task:
                state.isLoading = true
                effects.perform(id: load) {
                    defer { try? effects.modify { $0.isLoading = false } }  // also runs when cancelled
                    do {
                        let profile = try await client.fetch()
                        try effects.modify { $0.profile = profile }
                    } catch {
                        try Task.checkCancellation()  // cancelled: write no error state
                        try effects.modify { $0.errorMessage = "\(error)" }
                    }
                }
            case .cancelTapped:
                effects.cancel(load)
            }
        }
    }
}
```

The `defer` runs on every path, cancelled or not. A run that a second `.task` replaces runs it after the replacement has started, so `isLoading` can turn `false` while the second load is still running.

The test:

```swift
import Foundation
import Lattice
import Testing

final class StubProfileClient: ProfileClient {
    let name: String

    init(name: String) {
        self.name = name
    }

    nonisolated(nonsending) func fetch() async throws -> Profile {
        await Task.yield()  // suspends, so the result commits after `send` returns
        return Profile(name: name)
    }
}

@Suite
struct ProfileTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func loadsTheProfile() async {
        let model = await TestModel(
            initialState: ProfileState(),
            feature: Feature(interactor: ProfileInteractor(client: StubProfileClient(name: "Blob")))
        )
        await model.send(.task) { $0.isLoading = true }?.value
        await model.expect {  // the effect wrote its result, then its `defer` cleared the flag
            $0.profile = Profile(name: "Blob")
            $0.isLoading = false
        }
        await model.finish()
    }
}
```

Rules:

- Put `@available(iOS 26, macOS 26, watchOS 26, *)` on each `@Test`, and on each helper that names `TestModel`, not on the `@Suite`.
- Keep the suite nonisolated, without `@MainActor`. The interactor, its effect closures and the closures the test passes (`assert`, a `receive` predicate) must be formed in nonisolated code, such as file scope in the test target. A main-actor interactor, or a closure formed in a `@MainActor` test, is a compile error; such features use `TestViewModel`.
- Test doubles are plain classes or structs; they need no `Sendable` and no actors. Their async methods are `nonisolated(nonsending)`, because test targets usually do not enable `NonisolatedNonsendingByDefault`.
- `await model.state` crosses the actor, so it needs `State: Sendable`; internal value types are inferred `Sendable`. It is the state the test last asserted, `@Domain` members included, without the commits still pending.
- Set exhaustivity at `init` or with `await model.setExhaustivity(_:)`; a cross-actor property write is not expressible.
- A helper that receives a non-`Sendable` dependency and builds the model from it takes the parameter as `sending`, and forwards `fileID:filePath:line:column:` so that reports point at the test.
- End every exhaustive test with `await model.finish()`.

## What each assertion folds

- `send(_:assert:)` first handles what is pending: reported and consumed when exhaustive, skipped when `.off`. It then sends the action and folds the modifications its effects committed synchronously, in their preambles, up to the first action they sent. One `assert` describes the action's change and those modifications.
- The stub above suspends before it answers (`await Task.yield()`), so the result commits after `send` returns and `expect` describes it. An effect that never suspends finishes inside `send`, and `send`'s `assert` then describes its modifications too, up to the first action it sends.
- `expect { … }` is synchronous and does not wait. Await the effect first (`await model.send(…)?.value`), receive an action it sends, or wait for a signal it gives. It folds every pending modification up to the next action into one assertion, and with nothing pending it asserts the live state. When exhaustive, an action pending ahead of the modifications fails first: it needs `receive`.
- `receive` is for actions effects send, never for results: a result is a modification, asserted with `expect`. It waits until a matching action is pending, failing at once when no effect is left in flight, or until its timeout. It folds the entries before the match (when exhaustive, each non-matching action is reported), the match, and the modifications committed right after it, up to the next action.
- An assertion without an `assert` closure asserts that nothing changed, in every exhaustivity mode.

`receive` has three forms:

```swift
await model.send(.saveTapped) { $0.isSaving = true }
await model.receive(.saved(id: 7)) {  // Action: Equatable
    $0.savedID = 7
    $0.isSaving = false
}
await model.send(.saveTapped) { $0.isSaving = true }
await model.receive({ if case .saved = $0 { true } else { false } }) {  // a predicate
    $0.isSaving = false
}
await model.send(.saveTapped) { $0.isSaving = true }
await model.receive(\.saved, timeout: .seconds(2)) {  // Action: @CasePathable
    $0.isSaving = false
}
```

Here `SaveInteractor`'s `.saveTapped` effect saves the draft, sends `.saved(id:)` for a parent or sibling to react to, and clears `isSaving` in a `defer`, so each `receive` folds the action and that modification.

## Exhaustivity

- `Exhaustivity.on`, the default, requires every commit to be described: actions with `receive`, modifications with `expect`, or folded into the enclosing `send` or `receive`. What is still pending is reported at the next `send`, as leading actions at the next `expect` (which folds the pending modifications, so an undescribed one fails as that `expect`'s state diff), and at `finish`. A modification that leaves the state equal to what it was is exempt.
- `.off(showSkippedAssertions:)` skips what no assertion describes, to the latest state, before the next assertion. `showSkippedAssertions` defaults to `true`, so `.off()` reports every skip as a warning; pass `false` to skip silently. Under XCTest, IssueReporting turns warnings into failures.
- `skipReceived(strict:)` advances past every pending action and modification without asserting them. `skipInFlightEffects(strict:)` cancels every in-flight effect and waits for them; what they commit while they unwind stays pending, and the errors they throw are not reported. With `strict`, the default, each reports when there is nothing to skip.
- When the model is deallocated it reports what is still pending, but its `isolated deinit` runs without the test's context. Under Swift Testing that report is an unattributed warning that cannot fail the test; under XCTest it fails whichever test is running. That is why exhaustive tests end with `finish()`.

## State equality

Assertions compare states with the feature's `areStatesEqual`:

- `Feature(interactor:)` supplies `==` for an `Equatable` state.
- For a state that is not `Equatable`, or a comparison that ignores generated values such as IDs, build the feature with `Feature(interactor:areStatesEqual:)`.
- `TestModel(initialState:feature:areStatesEqual:)` and `TestViewModel(initialState:feature:areStatesEqual:)` cover a feature without an equality; the feature's own equality takes precedence over it.
- With no equality at all, the test model reports an issue at `init` and every state assertion fails.

```swift
let model = await TestModel(
    initialState: TodosState(),
    feature: Feature(
        interactor: TodosInteractor(clock: clock, autoSortDelay: .milliseconds(300)),
        areStatesEqual: todosStatesAreEqualIgnoringIDs
    )
)
```

## TestViewModel

For a main-actor-isolated interactor, such as one declared in a module with main-actor default isolation, use `TestViewModel` in a `@MainActor` test. Its `init` and `send` are synchronous, and `exhaustivity` and `timeout` are settable properties:

```swift
@MainActor
@Test
func savesOnTheMainActor() async {
    let model = TestViewModel(
        initialState: SaveState(draft: "Hello"),
        feature: Feature(interactor: SaveInteractor(client: StubSaveClient()))
    )
    model.timeout = .seconds(2)
    model.send(.saveTapped) { $0.isSaving = true }
    await model.receive(.saved(id: 7)) {
        $0.savedID = 7
        $0.isSaving = false
    }
    await model.finish()
}
```

## Time

Never call `TestClock.advance` right after `send`. `Clock.sleep` is `@concurrent`, so an effect registers its sleep only after it has hopped off the model's executor, and the advance can look for sleepers before that: it wakes nothing, and the test hangs or fails. Use a test-local gate clock, which lets the test wait for the sleep to register before it moves time:

```swift
@available(iOS 26, macOS 26, watchOS 26, *)
@Test(.timeLimit(.minutes(1)))
func debouncedSearchUsesTheLatestQuery() async {
    let clock = GateClock()
    let model = await TestModel(
        initialState: SearchState(),
        feature: Feature(interactor: SearchInteractor(clock: clock, debounceDuration: .milliseconds(300)))
    )
    await model.send(.queryChanged("a")) { $0.query = "a" }
    let search = await model.send(.queryChanged("b")) { $0.query = "b" }  // auto-cancels "a"
    await clock.waitForSleepers(1)  // "b" is asleep on the clock
    clock.moveForward(by: .milliseconds(300))  // wakes it before returning
    await search?.value
    await model.expect { $0.results = ["b"] }
    await model.finish()
}
```

`SearchInteractor` wraps its query interactor in `Interactors.Debounce(for: debounceDuration, clock: clock)`, and the interactor takes its clock as a generic parameter (`struct SearchInteractor<C: Clock>`). Loops, cancelled sleeps and waiting are in `resources/async-and-time.md`.

## Pitfalls

- `expect` can pass vacuously. Before an effect has run, `expect { _ in }` compares an unchanged state and passes. To assert that a cancelled effect wrote nothing, first prove that it ended (for example, `#expect(clock.pendingSleeps == [])` after the cancel, then await its task), then `expect`.
- Never await a looping effect's task, even a cancelled one: `await task?.value` is not cancellation-aware, and a `.timeLimit` cannot end it. Cancel the task, then end with `finish()`, which is bounded by its timeout.
- Never `TestClock.advance` right after `send`; wait for the sleep with a gate clock, one wait and one move per tick.
- A timer that sleeps with `try?` spins after a cancel, committing ticks: test clocks and `ContinuousClock` both throw at once. The interactor must write `try await clock.sleep(for:)`.
- An action the interactor ignores still cancels the anonymous effects of its case, so a test that re-sends a guarded action sees the running effect cancelled. The feature fixes that with `@EffectID`.
- An error that leaves a live effect fails the test (`Effect threw: …`). Errors thrown once the effect is cancelled, by any source including `skipInFlightEffects`, are not reported.
- Only one wait runs at a time: a `receive`, `finish` or `skipInFlightEffects` that overlaps another on the same model reports an issue and does nothing.
- An effect inherits the known-issue context of `withKnownIssue` when it is created. Start and await, inside the block, every effect whose reports the block expects.

## Production ViewModel tests

Only test production `ViewModel` behavior when you need to validate computed presentation members, observation, or event wiring. Reads go through the `ViewState` projection, exactly as in a view:

```swift
@MainActor
@Test
func countTextFollowsTheCount() {
    let viewModel = ViewModel(
        initialState: CounterState(count: 0),
        feature: Feature(interactor: CounterInteractor())
    )
    viewModel.sendViewEvent(.increment)  // synchronous: committed when it returns
    #expect(viewModel.countText == "1")
}
```

For an effect, await the task the send returns: `await viewModel.sendViewEvent(.refresh)?.value`.

## Tips

- Prefer `TestModel` for feature behavior and reserve production `ViewModel` tests for presentation-member, observation and wiring coverage.
- Keep assertions local to `send`, `receive` and `expect` blocks so the test documents the intended state transition at each step.
- These assertion APIs are non-throwing: call them without `try`.
- Cancel the task of an intentionally unbounded effect and end with `finish()`, or use `skipInFlightEffects()`.

## References
- See `resources/async-and-time.md` for the returned task, waiting, loops and time control.
- The Lattice repository's `specs/testing-infrastructure.md` has the full contract and every failure message.

# Testing Infrastructure

Lattice tests a feature through a test shell that runs the feature's `Core` exactly as production does, with effects starting on the shell's isolation and running their preambles before `send` returns, and that records every commit made outside the action under test until an assertion describes it. There are two shells over one engine, `TestHost`:

- `TestModel<F>`, an actor (iOS 26, macOS 26, watchOS 26): the primary test shell. Suites need not be `@MainActor`, and tests run in parallel.
- `TestViewModel<F>`, a `@MainActor` class: for interactors that are main-actor-isolated and for tests that must run on the main actor.

Key source files:

- [TestHost.swift](../Sources/Lattice/Testing/TestHost.swift): recording, folding, waiting
- [TestModel.swift](../Sources/Lattice/Testing/TestModel.swift), [TestViewModel.swift](../Sources/Lattice/Testing/TestViewModel.swift)
- [Received.swift](../Sources/Lattice/Testing/Received.swift), [Exhaustivity.swift](../Sources/Lattice/Testing/Exhaustivity.swift), [TestFailure.swift](../Sources/Lattice/Testing/TestFailure.swift), [TestIssueReporting.swift](../Sources/Lattice/Testing/TestIssueReporting.swift)
- [TestingInfrastructureTests](../Tests/LatticeTests/TestingInfrastructureTests): `TestModelSendTests`, `TestModelFoldingTests`, `TestModelExhaustivityTests`, `TestModelWaitingTests`, `TestModelCancellationTests`, `TestModelExampleTests`, `TestModelDeterminismTests`, `TestModelStateEqualityTests`, `TestModelNonSendableTests`, `TestModelEffectSequenceTests`, and the `TestViewModel` mirror `TestViewModelTests`
- Test support: [GateClock.swift](../Tests/LatticeTests/Support/GateClock.swift), [ReportedIssues.swift](../Tests/LatticeTests/Support/ReportedIssues.swift)

`Sources/Lattice/Testing` is excluded from the CocoaPods pod.

## Choosing A Shell

| | `TestModel` | `TestViewModel` |
|---|---|---|
| Kind | `public actor`, on its own `DefaultIsolation` executor | `@MainActor public final class`, on the main actor |
| Availability | iOS 26, macOS 26, watchOS 26 | the package's floors |
| `init` | `async`: `await TestModel(…)` | synchronous |
| `send` | `await model.send(…)` | synchronous |
| Exhaustivity | `setExhaustivity(_:)`, since cross-actor property writes are not expressible | a settable `exhaustivity` property |
| Timeout | the `init` parameter | the `init` parameter, or the settable `timeout` property |
| `receive`, `finish`, `skipInFlightEffects` | `async` | `async` |
| `expect`, `skipReceived` | synchronous on the model (`await` from the test) | synchronous |

Writing `TestModel` tests:

- Put `@available(iOS 26, macOS 26, watchOS 26, *)` on each `@Test`, and on each helper that names `TestModel`, not on the `@Suite`.
- Keep the suite nonisolated, without `@MainActor`. The interactor, its effect closures and the closures the test passes (`assert`, a `receive` predicate) must be formed in nonisolated code, such as file scope in the test target. A main-actor interactor or a closure formed in a `@MainActor` test is a compile error (see [Main-actor interactors](./effects-and-isolation.md#main-actor-interactors)). Such features use `TestViewModel`.
- `await model.state` crosses the actor, so it needs `State: Sendable`; otherwise it fails with `non-Sendable type '…State' … of property 'state' cannot exit actor-isolated context`. Internal value types are inferred `Sendable`. The `assert` closures work with any state.
- A helper that receives a non-`Sendable` dependency and builds the model from it takes the parameter as `sending`.
- Forward `fileID:`, `filePath:`, `line:` and `column:` from helpers that create models, so reports point at the test.

## Creating A Test Shell

```swift
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
```

The stub suspends before it answers, so the effect's modifications commit after `send` returns and `expect` describes them. An effect that never suspends finishes inside `send`, and `send`'s `assert` then describes its modifications too.

Both shells have the same two initializers, each with `exhaustivity: Exhaustivity = .on`, `timeout: Duration = .seconds(1)` and the caller's location:

- `init(initialState:feature:…)` compares states with the feature's `areStatesEqual`. `Feature(interactor:)` supplies `==` for an `Equatable` state, and `Feature(interactor:areStatesEqual:)` a custom comparison (the Todos example ignores generated IDs this way).
- `init(initialState:feature:areStatesEqual:…)` supplies the comparison for a feature that has none, such as one over a state that is not `Equatable`. The feature's own equality takes precedence.
- With no equality at all, `init` reports `The test model cannot compare '<State>' values: the feature has no state equality.` at the caller's location, and every state assertion then fails with the same message.
- The core always gets the feature's own equality, so commits are gated exactly as in production.

## What The Shell Records

```text
Core.didCommit(action?, state)          on the shell's isolation
  the root transition of the send under test   →  the new baseline (state)
  any other commit                             →  pending: Received(action?, resultingState), oldest first
      an action an effect sent                     action != nil, the state after its root transition
      a modification an effect made                action == nil
Core.effectsDidChange                   an effect started or finished: wakes a waiting call
```

- `state` is the baseline: the state the test last asserted or skipped to, `@Domain` members included. Pending commits are not in it.
- An assertion folds the run of pending entries it describes into one comparison: the baseline with `update` applied must equal the state after the last folded entry. No `update` asserts that nothing changed, in every exhaustivity mode.
- Entries that no assertion describes are consumed once they are handled: reported when exhaustive, skipped when `.off`, and the baseline advances past them.

## `send(_:assert:)`

1. Handles what is pending: exhaustive, it reports `Must handle <n received actions and m modifications> before sending another action.` and consumes it; `.off`, it skips it. Either way the send then runs.
2. Sends the action. Its root transition becomes the baseline.
3. Folds the modifications its effects committed synchronously, in their preambles, up to the first action they sent.
4. Asserts the baseline before the send, with `update` applied, against the result.
5. Returns the `Task<Void, Never>?` for the effects the action started (see [The Task `send` Returns](./effects-and-isolation.md#the-task-send-returns)).

So one `update` describes the action's change and its preambles' modifications. An action a preamble sent, and everything after it, stays pending.

## `receive`

Three overloads, each with `timeout:` (default: the shell's) and `assert:`:

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

`SaveInteractor`'s `.saveTapped` effect saves the draft, sends `.saved(id:)` for a parent or sibling to react to, and clears `isSaving` in a `defer`, so each `receive` folds the action and that modification.

- `receive` is for actions effects send. A result an effect writes with `modify` is asserted with `expect`.
- It waits until a matching action is pending, or until no effect is in flight, which fails at once, or until the timeout.
- It folds the entries before the match, the match, and the modifications committed right after it, up to the next action. When exhaustive, each non-matching action before the match is reported (`Received unexpected action before this one:`, with a diff against the expected action for the `Equatable` overload), and `update` must describe everything folded. With `.off`, the entries before the match are skipped, so `update` starts from the state right before the action.
- A failed `receive` reports the first pending action as unexpected (exhaustive), or that none arrived, then consumes everything pending:
  - `Expected to receive the following action, but didn't after 1.0 seconds:` and `There are effects in flight. If this action depends on time, make sure the clock has advanced far enough for the effect to send it.`
  - `…but didn't:` and `There are no in-flight effects that could send this action. The effect that sends it may have already finished or been cancelled.`, when nothing was in flight.
  - `…but didn't before the wait was cancelled:` when the waiting task was cancelled.
  - The predicate and case-path overloads say `Expected to receive an action matching predicate, but none arrived…` and `…an action matching case path…`.

## `expect(_:)`

`expect` asserts the modifications effects made: the results they wrote into state directly.

- It is synchronous and does not wait. Await the effect first (`await model.send(…)?.value`), receive an action it sends, or wait for a signal it gives.
- It first handles the actions pending ahead of the modifications: exhaustive, it reports `Must handle <n> received action(s) before 'expect'.` (they need `receive`); `.off`, it skips them.
- It then folds every modification up to the next action into one assertion. With nothing left pending, `update` is asserted against the live state.
- `expect` can pass vacuously. Before an effect has run, `expect { _ in }` compares an unchanged state and passes. To assert that a cancelled effect wrote nothing, first prove that it ended (for example, check that its sleep was cancelled, then await its task), then `expect`.
- A content-equal modification leaves no trace that an equality-based assertion can see.

## `finish(timeout:)`

- Waits until no effect is in flight, re-checking after every signal because effects start effects, and fails after the timeout with `Expected effects to finish, but <n> effect(s) remained in flight after <timeout>.` (`…when the wait was cancelled.` if the waiting task was cancelled).
- Then handles everything pending: exhaustive, `Received <n unexpected actions and m unasserted modifications> left unhandled.`; `.off`, skipped.
- End every exhaustive test with `finish()`.

## `skipReceived(strict:)` And `skipInFlightEffects(strict:)`

- `skipReceived` advances the baseline past every pending action and modification without asserting them. With `strict` (the default) and nothing pending, it reports `There were no received actions or modifications to skip.`
- `skipInFlightEffects` cancels every in-flight effect, again on every signal (a cancelled effect can still send an action that starts more), and waits up to the shell's timeout until none remain. What the effects commit while they unwind stays pending, to be asserted or skipped. With `strict` and nothing in flight, it reports `There were no in-flight effects to skip.`
- `skipInFlightEffects` is a cancellation source: errors thrown by the effects it cancels are not reported (see [Thrown Errors](./effects-and-isolation.md#thrown-errors)).

## Exhaustivity

`Exhaustivity` is `.on` by default.

- `.on` requires every commit to be described: actions with `receive`, modifications with `expect`, or folded into the enclosing `send` or `receive`. What is still pending is reported at the next `send`, as leading actions at the next `expect` (which folds the pending modifications, so an undescribed one fails as that `expect`'s state diff), at `finish`, and, as a warning, at deinit. A modification that leaves the state equal to what it was is exempt.
- `.off(showSkippedAssertions:)` skips what no assertion describes, to the latest state, before the next assertion: `send` skips everything pending, `receive` what precedes the match, `expect` the actions ahead of the modifications, and `finish` and deinit everything. `showSkippedAssertions` defaults to `true`, so `.off()` reports each skip as a warning (`Skipped 1 received action before receiving <action>.`, `Skipped 2 modifications before sending another action.`, `Skipped … at finish.`); pass `false` to skip silently. Under XCTest, IssueReporting turns warnings into failures.

| Checkpoint | `.on` | `.off` |
|---|---|---|
| `send` | report what is pending, consume it, then send | skip it, then send |
| `receive` | report each non-matching action before the match; fold everything up to the match and the modifications after it | skip what precedes the match; fold the match and the modifications after it |
| `expect` | report the leading actions; fold the modifications up to the next action | skip the leading actions; fold the same |
| `finish` | wait, then report what is pending | wait, then skip it |
| deinit | report what is pending, as a warning | skip it |

## Deinit

Each shell's `isolated deinit` hands what is still pending to the same handling, at the line that created the model, then cancels every effect.

- The report is a warning. An `isolated deinit` runs without the test's task-locals, so under Swift Testing the report is unattributed: it is recorded as a warning of an unknown test at the creation line, without its message text, because IssueReporting falls back to its XCTest path there. It cannot fail the test and cannot be asserted. Under XCTest, the same report fails whichever test is running.
- A `TestModel`'s deinit is a job on its executor; when the release is the test's last statement, the process can exit before it runs, and the report is lost.
- End exhaustive tests with `finish()`.

## Waiting

- `receive`, `finish` and `skipInFlightEffects` suspend on a signal stream that commits and effect starts and finishes yield, plus one detached deadline task per wait. Nothing waits by yielding, sleeping or polling.
- Timeouts are wall-clock (`ContinuousClock`) durations, not test-clock time.
- One wait at a time: a second `receive`, `finish` or `skipInFlightEffects` that overlaps a running one on the same model reports `The test model is already waiting for its effects, so this call did nothing: 'receive', 'finish' and 'skipInFlightEffects' each wait; await one before starting another.` and does nothing else (it consumes, settles and cancels nothing).
- A wait whose task is cancelled ends, and is reported as cancelled, not as a timeout. Later waits on the model work as usual.
- `await task?.value` on a task `send` returned is not cancellation-aware, and a `.timeLimit` cannot end it. Await only an effect that is proven to end. Never await the task of a looping effect, even a cancelled one: cancel it, then end with `finish()`, which is bounded by its timeout.

## Time

### The `TestClock` race

`TestClock.advance` right after a `send` races the effect's sleep:

```text
model executor                               global executor (Clock.sleep is @concurrent)
send(.queryChanged("b"))
  preamble → clock.sleep(for: 300 ms) ─hop─▶   [job queued]
send returns
await clock.advance(by: 300 ms)              ─▶ mega-yields, scans: no sleeper yet → returns
                                               [job runs] the sleep registers, after the advance
await task?.value                            → never ends; an `expect` would fail
```

The standard library's `Clock.sleep(for:)` and swift-clocks' `TestClock.sleep` are `@concurrent`, so an effect registers its sleep only after it has hopped off the model's executor, while `advance` only mega-yields before it scans for sleepers. After a wake-up the effect also has to hop back to the model before an `expect` can see its modification. This is a documented limitation. Lattice ships no clock of its own for it.

### The gate clock idiom

Tests use a test-local clock that lets the test wait for a sleep to register before it moves time. `GateClock` in [Tests/LatticeTests/Support](../Tests/LatticeTests/Support/GateClock.swift) is the reference, and each example package's test target has its own copy without the root's log hook: copy one into your own test target.

- `sleep(until:tolerance:)` registers the sleep under a lock. Sleeps are cancellation-aware: a cancel removes a registered sleep inside the `cancel()` call, and a sleep whose task was already cancelled never registers.
- `waitForSleepers(_:)` suspends until that many live sleeps exist, without polling. It ends when the waiting task is cancelled, so a `.timeLimit` stops a test that waits for a sleep that never comes.
- `moveForward(by:)` advances time and wakes every due sleep before it returns, soonest first.
- `pendingSleeps` lists the time left on each live sleep.

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

A loop needs one wait and one move per tick, because one move wakes only the sleeps registered at that moment. Waiting for the next sleep after the last move is how the test knows the loop has committed its tick, and its observers have fired:

```swift
let ticker = await model.send(.startTicking)
for _ in 1...3 {
    await clock.waitForSleepers(1)  // one wait …
    clock.moveForward(by: .seconds(1))  // … and one move per tick
}
await clock.waitForSleepers(1)  // asleep again: the third tick is committed
await model.expect { $0.ticks = 3 }  // three modifications, one assertion
ticker?.cancel()  // cancel the loop; never await its task
await model.finish()
```

Interactors take the clock as a generic parameter; see [Clock injection](./interactors.md#clock-injection).

## Asserting Reported Issues

The repository's tests assert the exact list of issues a block reports, with the helpers in [ReportedIssues.swift](../Tests/LatticeTests/Support/ReportedIssues.swift). They wrap the block in `withKnownIssue(isIntermittent: true)`, collect every issue the matcher sees, and return them, so the test can compare the list:

```swift
let issues = await reportedIssueDetails {
    let model = await TestModel(
        initialState: SaveState(draft: "Hello"),
        feature: Feature(interactor: SaveInteractor(client: StubSaveClient()))
    )
    await model.send(.saveTapped) { $0.isSaving = true }?.value
    await model.finish()  // `.saved` and the `defer`'s modification were never asserted
}
#expect(
    issues.map(\.heading) == ["Received 1 unexpected action and 1 unasserted modification left unhandled."]
)
```

- The intermittent known-issue scope never fails a test by itself; the comparison with the exact list is what catches a missing or an unexpected report.
- An effect inherits the known-issue context when it is created. Start and await, inside the block, every effect whose reports are expected; an effect created before it reports an ordinary failure.
- `reportedIssueDetails` also returns each issue's severity and location, which is how the suites check that exhaustive leftovers are errors and `.off` skips are warnings.

## Failure Reporting

- Assertions report through IssueReporting rather than by throwing. `reportTestFailure` is synchronous and nonisolated: it runs on the shell's isolation, in the test's task, so Swift Testing attributes the issue to the test (and `withKnownIssue` sees it) under both shells. The deinit report is the exception.
- Every assertion takes `fileID:filePath:line:column:` and reports at the caller. The deinit report points at the line that created the model.
- Messages: `A state change does not match expectation.` and `State was not expected to change, but a change occurred.` with a diff; `State assertion for <operation> threw error: <error>` for an `update` that throws; and the receive, finish, skip, overlap, exhaustivity and missing-equality messages above.

## Parallelism

`TestModel` runs each test's feature on its own executor, so nonisolated suites run in parallel on the cooperative pool: in `ParallelismTests`, 500 cases with a 1 ms blocking effect take about 0.15 s under `TestModel` against about 0.8 s for the same cases serialized on the main actor under `ViewModel`, on an 11-core machine.

## Related Specs

- [Effects And Isolation](./effects-and-isolation.md)
- [Interactors](./interactors.md)
- [ViewModel](./view-model.md)

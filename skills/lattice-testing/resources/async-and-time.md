# Async and Time

## The task `send` returns

- `let task = await model.send(...)` returns the `Task<Void, Never>?` for exactly the effects that action started. It is `nil` when the action started none, and it does not cover the effects started by actions those effects send.
- `await task?.value` waits for those effects. It is not cancellation-aware: cancelling the waiting test neither ends the wait nor cancels the effects, and a `.timeLimit` cannot end it. Await only effects that end by themselves.
- `task?.cancel()` cancels those effects, synchronously on OS 26. What they commit while they unwind is still recorded, to be asserted or skipped.
- `await model.finish()` waits for every in-flight effect, including effects started by other effects, bounded by its timeout, and then handles what is pending.

## Waiting

- `receive`, `finish` and `skipInFlightEffects` suspend on signals that commits and effect starts and finishes give; nothing polls or sleeps.
- Their timeouts are wall-clock durations, not test-clock time: one second by default, set by `init`'s `timeout:` or per call.
- Only one wait runs at a time. A second `receive`, `finish` or `skipInFlightEffects` that overlaps a running one on the same model reports `The test model is already waiting for its effects, …` and does nothing.
- A wait whose task is cancelled ends, and is reported as cancelled, not as a timeout.

## Time control

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

A test-local gate clock lets the test wait for the sleep to register before it moves time. Copy an example package's `GateClock.swift` from the Lattice repository, such as `ExampleProject/SearchExamplePackage/Tests/SearchExampleTests/GateClock.swift`, into your test target; the reference copy in `Tests/LatticeTests/Support/GateClock.swift` has a log hook that needs that folder's `EffectLog.swift`, so it does not compile on its own:

- `waitForSleepers(_:)` suspends until that many live sleeps exist, without polling. It ends when the waiting task is cancelled, so a `.timeLimit` stops a test that waits for a sleep that never comes.
- `moveForward(by:)` advances time and wakes every due sleep before it returns, soonest first.
- `pendingSleeps` lists the time left on each live sleep; `#expect(clock.pendingSleeps == [])` proves that a cancelled effect's sleep ended.
- Sleeps are cancellation-aware: a cancel removes a registered sleep inside the `cancel()` call, and a sleep whose task was already cancelled never registers.

For a debounced or delayed effect:

- assert the immediate state change in `send`'s `assert`
- `await clock.waitForSleepers(1)`: the effect is asleep on the clock
- `clock.moveForward(by: delay)`: wakes it before returning
- `await task?.value` for that send's effect, then `await model.expect { … }` its modification
- `await model.finish()`

A loop needs one wait and one move per tick, because one move wakes only the sleeps registered at that moment. Waiting for the next sleep after the last move is how the test knows that the loop has committed its tick:

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

## Debounced effects

- `Interactors.Debounce` sleeps at the top of every effect the child performs. Re-handling the action case cancels the sleeping effect, so after a burst of sends only the last effect is asleep: `waitForSleepers(1)` then sees exactly that one.
- An effect performed with an `@EffectID` is delayed too, and the next `perform` of its key replaces it.
- Interactors take the clock as a generic parameter (`struct SearchInteractor<C: Clock>`) with a `ContinuousClock` initializer for the app; tests pass the gate clock.

## Cancelled effects

- An effect cancelled by automatic cancellation, `cancel(_:)`, replacement by key, `skipInFlightEffects`, teardown or cancelling the returned task reports none of the errors it throws.
- A cancelled effect keeps running until its next cancellation-aware suspension, and its modifications are still committed and recorded.
- To assert that a cancelled effect wrote nothing, first prove that it ended, for example with `#expect(clock.pendingSleeps == [])` after the cancel and then by awaiting its task, and only then `expect`. Before that, `expect { _ in }` passes vacuously.

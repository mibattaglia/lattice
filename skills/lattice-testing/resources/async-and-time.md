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

Inject an `EffectClock` and move time with the test shell's `advance(_:by:)`:

- The effect's `try await clock.sleep(for:)` binds to Lattice's `nonisolated(nonsending)` overload, which registers the sleep on the `EffectClock` on the shell's isolation, before the effect first suspends: the sleep is registered when `send` returns.
- `await model.advance(clock, by: duration)` wakes every sleep due by the new time, in deadline order, moving time to each deadline as it wakes it. After each wake it waits until the woken effect has run to its next suspension: committed and slept again, finished, or parked on something else, which does not hold it up. The wait is a handshake with the woken effect, not a `Task.yield()`.
- Sleeps are cancellation-aware: a cancel removes its effect's sleep inside the `cancel()` call, so an `advance` to when it was due wakes nothing, and a sleep whose task is already cancelled throws without registering.
- Use one clock per model: `advance` waits for woken effects on its own shell.

For a debounced or delayed effect:

- assert the immediate state change in `send`'s `assert`
- `await model.advance(clock, by: delay)`: the effect wakes and runs to its next suspension
- `await model.expect { … }` its modification; when the woken effect then waits on a dependency that suspends, wait for that first, for example with `await task?.value`
- `await model.finish()`

One `advance` moves a loop through every tick in its duration, because each woken tick commits and sleeps again, one interval after the deadline it woke at, before the next wake:

```swift
let ticker = await model.send(.startTicking)
await model.advance(clock, by: .seconds(3))  // three wakes, each run to the loop's next sleep
await model.expect { $0.ticks = 3 }  // three modifications, one assertion
ticker?.cancel()  // cancel the loop; never await its task
await model.finish()
```

## Sleeps that register late

The standard library's `sleep(for:tolerance:)` and `sleep(until:tolerance:)` are `@concurrent`. An effect that sleeps through them hops to the global executor first, so the sleep reaches the clock after `send` returned, and an `advance` right after the `send` can miss it:

```text
model executor                               global executor (sleep(until:tolerance:) is @concurrent)
send(.queryChanged("b"))
  preamble → sleep(for:tolerance:) ─hop─▶      [job queued]
send returns
await model.advance(clock, by: 300 ms)       no sleep registered yet → wakes nothing
                                               [job runs] the sleep registers, late
```

`EffectClock` reports every sleep that reaches it with no caller isolation, `EffectClock registered this sleep late: …`: `sleep(for:tolerance:)`, `Task.sleep(for:clock:)`, `sleep(until:tolerance:)` on a generic clock, and `clock.sleep(for:)` inside a `@concurrent` function. `sleep(until:)` called on a concrete `EffectClock` runs on the caller's isolation and is not reported. Spell the sleep `try await clock.sleep(for:)` on the effect's isolation, in a file that imports Lattice.

## Debounced effects

- A debounce is `try await clock.sleep(for:)` at the top of the effect. Re-handling the action case cancels the sleeping effect inside that `send`, so after a burst of sends only the last effect is asleep, and one `advance` past the delay runs exactly that one.
- An effect performed with an `@EffectID` is replaced by the next `perform` of its key instead, and an action the interactor ignores leaves it alone.
- Interactors take the clock as a generic parameter (`struct SearchInteractor<C: Clock>`) with a `ContinuousClock` initializer for the app; tests pass an `EffectClock`.

## Cancelled effects

- An effect cancelled by automatic cancellation, `cancel(_:)`, replacement by key, `skipInFlightEffects`, teardown or cancelling the returned task reports none of the errors it throws.
- A cancelled effect keeps running until its next cancellation-aware suspension, and its modifications are still committed and recorded.
- To assert that a cancelled effect wrote nothing, first prove that it ended, and only then `expect`; before that, `expect { _ in }` passes vacuously. For a one-shot effect, `advance` to when its sleep was due, which wakes a sleep that outlived the cancel, then await its task. For a loop, whose task is never awaited, `advance` one interval and `expect { _ in }`, then end with `finish()`, which waits for the loop to end and reports anything it wrote.

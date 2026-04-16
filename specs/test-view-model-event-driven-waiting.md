# TestViewModel TCA-Matched Waiting Plan

## Goal

Align `TestViewModel` and `TestEventTask` waiting behavior with TCA's actual `TestStore`
implementation rather than inventing a more elaborate waiting system.

This means the plan should prefer the same kinds of synchronization TCA uses today:

- one small `AsyncStream` signal for emission startup
- `ContinuousClock` deadlines for assertion timeouts
- `Task.yield()` / `Task.megaYield()` style polling loops for `receive` and `finish`
- a task-group race between the underlying task and `Task.sleep(for:)` for task handles

This plan explicitly does _not_ pursue a custom continuation-based waiting runtime.

## Decision summary

The previous version of this plan proposed:

- arrays of checked continuations for root-scope completion
- a shared execution-change notifier
- a custom injected timeout driver

That is no longer the direction.

Instead, Lattice should match TCA more closely:

1. Do not maintain waiter registries or multicast continuation arrays.
2. Add at most one TCA-style startup signal using `AsyncStream.makeStream(of: Void.self)`.
3. Use `ContinuousClock` plus polling for `receive` and `finish`.
4. Use a `withThrowingTaskGroup` timeout race for `TestEventTask.finish`.
5. Keep the public testing API and issue-reporting direction already established.

## Why match TCA here

From an engineering perspective, the main objection raised was not just "polling is bad." The
stronger objection was "do not replace simple waiting behavior with a custom waiter runtime that
needs careful continuation lifecycle management."

TCA's `TestStore` is the relevant bar for this repo. It does not maintain arrays of checked
continuations, and it does not implement a generalized event-driven wait engine.

It uses a simpler shape:

- one stream to learn that emission work has begun
- state polling with deadlines for `receive` and `finish`
- a task-group race for task-handle finishing

If Lattice is trying to mirror TCA's testing ergonomics, it should mirror that shape too.

## Grounding in TCA

These observations come from the local TCA copy in:

- `/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture`

Relevant implementation points:

- `TestStore.send` waits for startup using `effectDidSubscribe.stream` or `Task.yield()`
- `TestStore.finish` uses `ContinuousClock` and a `Task.yield()` loop
- `TestStore.receiveAction` uses `ContinuousClock`, `Task.megaYield()`, and a detached background
  yield
- `TestStoreTask.finish` races the underlying task against `Task.sleep(for:)`
- `TestReducer` stores only simple state and one `AsyncStream.makeStream(of: Void.self)` startup
  signal

## Non-goals

- building a generalized waiter/broadcaster system for the testing runtime
- introducing arrays of checked continuations
- making `TestViewModel` generic over a clock
- adding a custom timeout dependency layer not present in TCA
- changing step-wise buffering semantics
- changing exhaustivity semantics

## Proposed design

### 1. Use a single startup signal like TCA

TCA uses:

```swift
let effectDidSubscribe = AsyncStream.makeStream(of: Void.self)
```

and yields into it when work subscribes, or immediately when there is no emission work.

Lattice should adopt the same general idea for send-scoped startup synchronization.

Recommended adaptation:

- add one `AsyncStream.makeStream(of: Void.self)` style signal to the test runtime
- yield into it when an emission starts in a way that matters for post-send assertions
- also yield for "no emission work" so the send path does not hang waiting for startup

This signal should replace the current `awaitEffectStartup(for:)` yield hack.

Important boundary:

- this stream is only for startup coordination
- it is not a general completion or state-change bus

### 2. Do not add continuation arrays

Do not add:

- `rootScopeWaiters: [SendScopeID: [CheckedContinuation<Void, Never>]]`
- model-wide continuation registries
- multicast continuation fan-out infrastructure

That design is more complicated than what TCA uses and would add lifecycle risk without being
necessary to match `TestStore`.

### 3. Keep `finish` aligned with TCA's polling style

TCA's `TestStore.finish`:

- asserts there are no unhandled received actions
- computes a `ContinuousClock` deadline
- yields to the scheduler
- loops until `inFlightEffects` is empty or the deadline expires

Lattice should mirror that for `TestViewModel.finish`.

Recommended shape:

- keep `waitForEffectsToFinish(timeout:)`
- use `ContinuousClock`
- use `Task.yield()` or the minimal TCA-style equivalent for polling
- report issue text at the caller site through the existing issue-reporting path

The goal here is not to design the theoretically cleanest waiting runtime. The goal is to match
TCA's observable testing behavior and implementation style.

### 4. Keep `receive` aligned with TCA's polling style

TCA's `receiveAction` also uses a deadline loop instead of a notifier system.

Lattice should do the same for `waitForPendingReceive`.

Recommended shape:

- keep the current "check state, yield, re-check" structure
- use `ContinuousClock` deadline logic
- if needed, follow TCA and use a detached background `Task.yield()` step to help the scheduler
  flush work
- preserve exhaustivity-specific readiness semantics

This means no execution-version counters and no custom wake-up channels.

### 5. Make `TestEventTask.finish` match `TestStoreTask.finish`

This is the clearest place to match TCA exactly.

TCA's task handle:

- does an initial `Task.megaYield()`
- races the underlying task against `Task.sleep(for:)` using `withThrowingTaskGroup`
- reports a timeout issue if sleep wins

Lattice should do the same for `TestEventTask.finish(timeout:)`.

Recommended shape:

```swift
await Task.megaYield()
do {
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await rawValue?.value }
    group.addTask {
      try await Task.sleep(for: duration)
      throw CancellationError()
    }
    try await group.next()
    group.cancelAll()
  }
} catch {
  report timeout issue at caller location
}
```

This means:

- remove the current `CompletionState` actor
- remove the millisecond sleep loop in `TestEventTask.finish`
- do not add a custom timeout driver

### 6. Match TCA's philosophy for task handles

TCA's `TestStoreTask` is just a task handle plus timeout configuration. Lattice should preserve the
same idea.

That means `TestEventTask` should remain:

- a lightweight wrapper over the underlying send-scoped task
- not a custom completion system
- not a waiter registry

If Lattice's root-scope implementation cannot yet express completion as a naturally finishing task,
that should be solved as directly as possible without introducing a generalized continuation layer.

### 7. Keep the existing issue-reporting boundary

This waiting plan does not change the issue-reporting direction:

- public APIs remain non-throwing
- internal helpers may still throw
- public APIs catch and report issues at the caller site

The change is only about _how waiting is implemented_, not about reverting the public assertion
contract.

## File-level implications

### `Sources/Lattice/Testing/TestViewModel/TestViewModel.swift`

- keep non-throwing public APIs
- replace `awaitEffectStartup(for:)` with a TCA-style startup signal
- keep `waitForPendingReceive` and `waitForEffectsToFinish` as deadline loops
- do not introduce execution-version wait channels

### `Sources/Lattice/Testing/TestViewModel/TestEventTask.swift`

- replace the current `CompletionState` + sleep loop implementation
- use a `withThrowingTaskGroup` timeout race like `TestStoreTask.finish`
- keep caller attribution and non-throwing public surface

### `Sources/Lattice/Internal/Execution/RootScopeTasks.swift`

This file should not grow into a custom waiting abstraction.

Two acceptable directions:

- simplify it so it better matches TCA's task-handle model
- or inline/remove it if it is only wrapping behavior that no longer needs a dedicated helper

What should not happen:

- turning it into a continuation-based multicast completion registry

## Implementation outline

### Phase 1. Replace the previous custom-waiting proposal

- remove continuation-array and execution-notifier ideas from the plan
- document TCA as the reference behavior

### Phase 2. Add a TCA-style startup signal

- add a single `AsyncStream.makeStream(of: Void.self)` style signal to the test runtime
- yield when emission work subscribes/starts
- use it to replace `awaitEffectStartup(for:)`

### Phase 3. Normalize polling loops

- keep `ContinuousClock` deadline logic for `receive` and `finish`
- prefer the same yield patterns TCA uses
- do not add custom timeout injection infrastructure

### Phase 4. Rework `TestEventTask.finish`

- use TCA's task-group timeout race
- remove the current custom completion-state polling logic

## Success criteria

- no continuation arrays or waiter registries are introduced
- `TestEventTask.finish` matches TCA's task-group timeout style
- `TestViewModel.receive` and `finish` use TCA-style deadline polling
- startup synchronization uses one simple stream signal rather than ad hoc yields
- caller-site issue attribution remains correct

## Tradeoffs

### This does not eliminate polling

Correct. TCA itself still polls for `receive` and `finish`.

If the explicit goal is "match TCA," then retaining polling in those paths is acceptable.

### This is not the theoretically cleanest runtime

Also correct. A more event-driven design may be possible, but it would move Lattice away from TCA's
current implementation shape and introduce more custom infrastructure than desired.

### Why keep one stream at all

Because TCA does. The stream solves one narrow synchronization problem cleanly: emission startup
after `send`.

That is materially different from building a general waiter runtime.

## Risks

- TCA-style polling still depends on scheduler behavior
- Lattice may need a little adaptation because it has root scopes while TCA does not
- `Task.megaYield()` may need a local equivalent if Lattice wants to match TCA closely

These are acceptable risks if the priority is fidelity to TCA over a more ambitious redesign.

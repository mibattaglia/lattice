# Debounce Cancel-In-Flight Plan

## Goal

Fix the flaky behavior in `DebounceInteractorTests.effectsAreDebounced()` by moving `Interactors.Debounce` closer to TCA's current model:

- debounce = `sleep(for:)` + cancel-in-flight
- winner chosen by serialized send/spawn order
- scope the first patch to top-level one-shot `.perform` emissions
- small `OSAllocatedUnfairLock`-backed task registry is acceptable
- prefer a simple runtime change over actor/session/lane machinery

This plan intentionally favors implementation simplicity over a maximally generalized concurrency design.

## What TCA Does

Modern TCA no longer treats debounce as a special runtime subsystem.

The common pattern is:

1. return a `.run` effect
2. `try await clock.sleep(for: ...)`
3. perform the real work
4. mark the effect `.cancellable(id:cancelInFlight: true)`

The important property is not the sleep itself. The important property is that cancellation is registered when the store launches the effect from its serialized send loop, not later when some nested async closure eventually begins running.

That is the model this plan follows.

## Why Lattice Flakes Today

Current flow:

1. `Interactors.Debounce.interact` mutates state synchronously and returns an `Emission`.
2. The wrapper currently delegates to `Emission.debounce(using:)`.
3. `Emission.debounce(using:)` registers with `Debouncer` inside the returned `.perform` closure.
4. That closure only starts later, when `EmissionExecution.spawnTasks` launches effect tasks.

This means debounce winner selection currently depends on task-start order, not send order.

That is the bug.

## Desired Semantics

This patch should preserve:

- immediate synchronous state mutation
- immediate `.action` emissions
- existing public `Interactors.Debounce(for:clock:child:)` API
- existing public `Debouncer` and `Emission.debounce(using:)` API in the first patch

This patch should change:

- `Interactors.Debounce` should no longer use `Debouncer` as its implementation strategy
- debounce cancellation should be decided when the runtime spawns the effect
- a later send should cancel the earlier debounced effect before that earlier effect's delay window opens
- the first patch should only debounce top-level `.perform` emissions returned by the wrapped interactor

## Decision Summary

Rebuild `Interactors.Debounce` around a TCA-style cancel-in-flight task model:

- `Interactors.Debounce` attaches internal debounce metadata only when the child returns a top-level `.perform`
- `EmissionExecution` sees that metadata only in the `.perform` spawn path
- the runtime registers the new task synchronously in a small `OSAllocatedUnfairLock`-backed registry
- registering the new task cancels the previous task for the same debounce token
- the new task sleeps, then executes the real work if it was not cancelled

No debounce lane. No session actor. No `AsyncStream` submission pipeline.

## Scope

This plan is intentionally narrow.

The first patch is optimized for:

- the failing `DebounceInteractorTests.effectsAreDebounced()` path
- the common case where a debounced interactor returns a top-level `.perform`
- TCA-like one-shot debounce behavior rather than general async-tree debouncing

For this patch:

- top-level `.perform` is debounced
- `.none` and `.action` pass through unchanged
- `.observe`, `.merge`, and `.append` are unsupported and should `fatalError`

This is intentionally narrower than the recursive behavior of `Emission.debounce(using:)`, but it matches the intended use of `Interactors.Debounce` and avoids teaching the executor a generalized debounce protocol it does not need. Failing fast is preferable to silently accepting unsupported semantics.

## Proposed Design

### 1. Stop using `Emission.debounce(using:)` inside `Interactors.Debounce`

Current code:

- child interactor returns an `Emission`
- `Interactors.Debounce` immediately calls `.debounce(using: debouncer)`

Replace that with:

- child interactor still runs immediately
- if the child returns a top-level `.perform`, `Interactors.Debounce` attaches internal debounce execution metadata
- if the child returns `.none` or `.action`, return it unchanged
- if the child returns `.observe`, `.merge`, or `.append`, `fatalError` with an explicit unsupported-usage message

This moves debounce from "nested work wrapper" to "effect launch policy".

### 2. Add internal execution metadata to `Emission`

Add minimal internal-only metadata to `Emission` with no public API change.

One reasonable shape:

```swift
struct EmissionExecutionOptions: Sendable {
    var debounce: DebounceExecutionOptions?
}

struct DebounceExecutionOptions: Sendable {
    let token: DebounceToken
    let sleep: @Sendable () async throws -> Void
}
```

Notes:

- this is internal metadata, not a new public `Emission.Kind`
- the metadata is attached by internal helpers only
- the metadata is only used for top-level `.perform` execution
- `.observe`, `.merge`, and `.append` do not participate in this first patch because `Interactors.Debounce` rejects them before execution

The `sleep` closure keeps the metadata simple and avoids fighting generic clock storage at the execution layer.

One possible helper shape:

```swift
func withDebounceExecution(
    token: DebounceToken,
    sleep: @escaping @Sendable () async throws -> Void
) -> Emission<Action>
```

That helper should only be called by `Interactors.Debounce` when the child emission kind is `.perform`.

### 3. Give each `Interactors.Debounce` instance one stable token

`Interactors.Debounce` should own one internal debounce token for its lifetime.

Pseudo-shape:

```swift
private let debounceToken = DebounceToken()
```

Then `interact` becomes:

1. run the child immediately
2. inspect the returned emission
3. if it is `.perform`, attach debounce metadata with this token
4. if it is `.none` or `.action`, return it unchanged
5. if it is `.observe`, `.merge`, or `.append`, `fatalError`

This makes "later action wins" map cleanly to "later spawned effect replaces earlier task for this token".

### 4. Add a simple `OSAllocatedUnfairLock`-backed `EffectCancellationRegistry`

Add a small internal registry modeled after TCA's cancellation storage and after Lattice's existing `EffectTaskRegistry`.

Use `OSAllocatedUnfairLock` rather than `NSLock` here:

- Lattice's deployment targets support it
- it is a better fit for Swift 6 `Sendable` checking
- it lets the registry store its protected state directly in the lock
- it avoids needing `@unchecked Sendable` on the registry itself

Suggested shape:

```swift
import os

final class EffectCancellationRegistry: Sendable {
    private let state = OSAllocatedUnfairLock<
        [DebounceToken: Task<Void, Never>]
    >(uncheckedState: [:])

    func replace(
        _ task: Task<Void, Never>,
        for token: DebounceToken
    ) -> Task<Void, Never>?

    func removeCurrentTask(
        _ task: Task<Void, Never>,
        for token: DebounceToken
    )

    func cancelAll()
}
```

Important behavior:

- `replace` stores the new task and returns the previous one
- the previous task is cancelled outside the lock
- `removeCurrentTask` only removes the entry if the stored task is still the same task instance
- `cancelAll` mirrors the current deinit cleanup style already used elsewhere in the runtime
- use `withLock`, not manual `lock()` / `unlock()`

This is deliberately simple. Small lock usage is acceptable here.

### 5. Apply debounce only in the `.perform` branch of `EmissionExecution`

`EmissionExecution.spawnTasks` should accept the new cancellation registry.

In the `.perform` branch:

1. create one root task for that debounced effect
2. register it immediately in `EffectCancellationRegistry`
3. cancel the previously registered task for the same token
4. inside the task body:
   - `try await sleep()`
   - `guard !Task.isCancelled else { return }`
   - execute the underlying emission
5. on completion or cancellation, remove the current task from the registry if still installed

The key change is timing:

- registration happens synchronously from the serialized spawn path
- not later from inside delayed user work

That makes winner selection follow send/spawn order.

All other branches should remain structurally unchanged in this patch:

- `.none` and `.action` stay as they are
- `.observe` keeps the existing streaming path
- `.merge` keeps the existing child task spawning behavior
- `.append` keeps the existing sequential parent-task behavior

This is the main narrowing from the previous draft. The executor should not gain a new inline debounce execution mode, and in normal use it should never see debounce metadata attached to `.observe`, `.merge`, or `.append`.

## Why This Is Simpler

This plan removes the over-engineered parts from the previous draft:

- no session actor
- no worker lane task
- no `AsyncStream` handoff just to establish order
- no actor choreography around activation/supersession state

Instead, it uses:

- one stable debounce token
- one `OSAllocatedUnfairLock`-backed registry
- one task replacement rule
- one delayed tracked `.perform` task

That is a much closer match to TCA's current approach.

## Files To Change

### `Sources/Lattice/Domain/Interactor/Interactors/Debounce.swift`

Rewrite `Interactors.Debounce` so it:

- stops storing a public `Debouncer`
- stores an internal debounce token
- when the child returns `.perform`, attaches internal debounce metadata instead of calling `Emission.debounce(using:)`
- when the child returns `.none` or `.action`, passes the emission through unchanged
- when the child returns `.observe`, `.merge`, or `.append`, traps with a clear `fatalError`

### `Sources/Lattice/Domain/Emission.swift`

Add minimal internal execution metadata and a focused helper such as:

- `withDebounceExecution(...)`

No public API change should be required.

### `Sources/Lattice/Internal/EffectCancellationRegistry.swift`

Add the new `OSAllocatedUnfairLock`-backed registry used for cancel-in-flight behavior.

### `Sources/Lattice/Internal/Execution/EmissionExecution.swift`

Add:

- debounce-aware `.perform` spawn path
- registry cleanup on completion/cancellation

### `Sources/Lattice/Presentation/ViewModel/ViewModel.swift`

Add an instance-owned `EffectCancellationRegistry` and pass it into `EmissionExecution.spawnTasks`.

### `Sources/Lattice/Testing/TestViewModel/TestViewModel.swift`

Mirror the same registry wiring used by `ViewModel`.

### `README.md`

Clarify the semantics:

- state changes are immediate
- `Interactors.Debounce` is implemented as action-ordered cancel-in-flight debounce for one-shot effect emissions
- the wrapper is closer to TCA's `sleep + cancellable(id:cancelInFlight:)` pattern than to the lower-level `Debouncer` utility

## Tests

### Keep and tighten the existing regression

`DebounceInteractorTests.effectsAreDebounced()` should keep asserting:

- all state changes happen immediately
- only one effect executes
- the winning result is `3`

It should also finish all root tasks created by the three sends, not just the last one.

### Add focused runtime tests

Add at least one focused test around the new spawn-time cancellation path.

Useful coverage:

1. later debounced effect cancels earlier one even if the earlier task body would have started later
2. canceling a root scope cancels the currently registered debounced task
3. `Interactors.Debounce` only transforms top-level `.perform`
4. `Interactors.Debounce` traps on `.observe`, `.merge`, and `.append`

For the trap behavior:

- add crash tests if the repo already has a practical harness
- otherwise document the expected `fatalError` messages and validate manually in the first patch

### Leave these tests in place

- `DebouncerTests`
- `EmissionDebounceTests`

Those tests still matter because the public lower-level API remains in the package for now.

## Non-Goals

This patch does not need to:

- redesign `Debouncer`
- deprecate `Emission.debounce(using:)`
- remove all lock usage
- move deep interactor logic onto `MainActor`
- debounce `.observe`
- debounce higher-order emissions such as `.merge` and `.append`
- solve mixed immediate-action/async emission trees

Those unsupported higher-order shapes should fail fast rather than being partially supported.

## Validation Plan

Run at least:

```bash
swift test --filter DebounceInteractorTests
swift test --filter EmissionExecutionTests
swift test --filter DebouncerTests
swift test --filter EmissionDebounceTests
swift test --filter LatticeTests
```

Stress the flaky case:

```bash
for i in {1..100}; do
  swift test --skip-build --filter 'LatticeTests.DebounceInteractorTests/effectsAreDebounced()' || break
done
```

Expected outcome:

- no more `.effectCompleted(2)` winning over `.effectCompleted(3)`
- ordering now follows serialized send/spawn order
- implementation is materially simpler than the actor/session/lane approach

## Follow-Up Work

After the bug is fixed, reassess separately:

1. whether `Interactors.Debounce` should eventually replace or deprecate the lower-level `Emission.debounce(using:)` path
2. whether `Interactors.Debounce` should ever grow support for `.observe`, `.merge`, or `.append` instead of trapping
3. whether the runtime should eventually expose a more general internal cancellation-ID mechanism beyond debounce

None of that should block this patch.

## Phases

### Phase 1: Rework `Interactors.Debounce`

- stop using `Emission.debounce(using:)`
- keep immediate child interactor execution
- pass through `.none` and `.action`
- attach internal debounce execution metadata only to top-level `.perform`
- trap on unsupported `.observe`, `.merge`, and `.append`

### Phase 2: Add Internal Debounce Execution Metadata

- add minimal internal execution metadata to `Emission`
- add a focused helper such as `withDebounceExecution(...)`
- keep the change internal with no public API expansion

### Phase 3: Introduce Stable Debounce Tokens

- give each `Interactors.Debounce` instance one stable internal token
- use that token to identify the currently winning in-flight debounced task

### Phase 4: Add Cancel-In-Flight Registry

- add `EffectCancellationRegistry`
- back it with `OSAllocatedUnfairLock`
- support task replacement, conditional removal, and cleanup

### Phase 5: Apply Debounce at Effect Spawn Time

- update `EmissionExecution` so debounce is handled in the `.perform` spawn path
- register the new task before delay begins
- cancel the previously registered task for the same token
- clean up registry state on completion or cancellation
- wire the registry through `ViewModel` and `TestViewModel`

### Phase 6: Document the Runtime Semantics

- update `README.md`
- clarify that state mutation remains immediate
- clarify that `Interactors.Debounce` is now action-ordered cancel-in-flight debounce for one-shot effects

### Phase 7: Tighten and Expand Test Coverage

- keep and tighten `DebounceInteractorTests.effectsAreDebounced()`
- add focused runtime coverage for spawn-time cancellation
- verify scope cancellation behavior
- cover top-level `.perform` handling and unsupported emission shapes
- retain `DebouncerTests` and `EmissionDebounceTests`

### Phase 8: Validate and Stress the Fix

- run the focused debounce, execution, and package test suites
- stress the flaky debounce regression repeatedly
- confirm serialized send/spawn order now determines the winner

# Feature Runtime Implementation Plan

This document is the project-level implementation plan for the feature-runtime redesign.

It turns the research in [`README.md`](/Users/michaelbattaglia/Documents/lattice/lattice/specs/feature-runtime/README.md) into an execution plan for autonomous coding agents, and it now assumes the ownership-collapsed no-hooks direction described in [`feature-runtime-update-plan.md`](/Users/michaelbattaglia/Documents/lattice/lattice/specs/feature-runtime/feature-runtime-update-plan.md).

Use the documents this way:

- [`README.md`](/Users/michaelbattaglia/Documents/lattice/lattice/specs/feature-runtime/README.md): research and source-backed grounding
- [`feature-runtime-update-plan.md`](/Users/michaelbattaglia/Documents/lattice/lattice/specs/feature-runtime/feature-runtime-update-plan.md): detailed runtime redesign with code sketches and diffs
- this file: project sequencing, scope boundaries, acceptance criteria, and migration order

## Settled decisions

These are the decisions this plan assumes:

- Public testing API: `TestViewModel<F>` only.
- Gold standard: TCA `TestStore` semantics and diagnostics, adapted into Lattice terminology and architecture.
- Do not add `FeatureRuntime.Hooks` or any other registered observer/callback surface on a shared runtime object.
- Do not add a production/test mode enum.
- Do not add a separate `Driver` abstraction for the synchronous interactor step.
- Collapse execution ownership upward:
  - `ViewModel` owns production execution.
  - `TestViewModel` owns test execution.
- Share semantics through small internal helper types/functions, not a long-lived observable `FeatureRuntime`.
- Keep the package annotation-driven; do not change package-level isolation defaults in [`Package.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Package.swift) or [`Package@swift-6.2.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Package@swift-6.2.swift).
- Keep execution on `@MainActor` unless there is a specific demonstrated need not to.
- Test buffering intercepts all emitted actions, including synchronous `.action`.
- Test `finish()` matches TCA: effects finish, queued receives stay queued until explicitly `receive`d or skipped.
- `.append` continues against internal latest state, not test-visible asserted state.
- Cancellation stops future emissions but does not erase already-buffered receives.
- Harness strategy: no incremental compatibility period. Replace harness-based testing with `TestViewModel`, then remove [`InteractorTestHarness.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift).

## Change in direction

The previous version of this plan tried to keep [`FeatureRuntime.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift) as a long-lived shared executor and layer hooks plus a coordinator on top.

That is no longer the target design.

Why:

- it kept execution ownership and visible-state ownership in different objects
- it made a callback seam inevitable for post-`send` effect output
- it pushed `FeatureRuntime` toward becoming both engine and event source
- it made testing depend on observing runtime behavior after the fact instead of owning test-visible progression directly

The new direction is simpler:

- shared helper files preserve the hard semantics
- `ViewModel` applies production visibility rules directly
- `TestViewModel` applies test visibility rules directly
- no long-lived observable runtime object remains in the final design

## TCA grounding

TCA does not solve this with a callback protocol or runtime observer seam.

Production TCA colocates ownership:

- `Core` / `Store` owns state
- `Core` / `Store` owns the buffered send loop
- effects re-enter the same owner

Testing TCA gets its seam before visible state advances:

- `TestStore` wraps reducer execution
- it buffers received actions
- it tracks in-flight effects and effect-start signals

Lattice does not need to copy TCA's reducer/store DSL. The relevant lesson is the ownership boundary:

- the object deciding production-visible state should own production execution
- the object deciding test-visible state should own test execution

That maps to:

- `ViewModel<F>` in production
- `TestViewModel<F>` in tests

## Architecture summary

The finished design has three layers:

1. Interactor mutation step
   - `interactor.interact(state:action:)` remains the synchronous mutation primitive

2. Shared execution helpers
   - internal-only
   - small value types and helper functions
   - action application
   - emission execution
   - root-scope bookkeeping
   - root-scope `finish()` / cancellation support

3. Public owners
   - `ViewModel<F>` owns production execution and production-visible view-state updates
   - `TestViewModel<F>` owns test execution, pending receives, diagnostics, and exhaustivity

The core rule is:

- production-visible state and production execution belong to the same owner
- test-visible state and test execution belong to the same owner

That removes the need for runtime hooks.

## File layout target

The exact split can move a little during implementation, but the target shape is:

```text
Sources/Lattice/Internal/FeatureRuntime.swift                       # delete by end of project
Sources/Lattice/Internal/Execution/ActionSource.swift
Sources/Lattice/Internal/Execution/ActionTransition.swift
Sources/Lattice/Internal/Execution/BufferedAction.swift
Sources/Lattice/Internal/Execution/SendScopeID.swift
Sources/Lattice/Internal/Execution/EffectID.swift
Sources/Lattice/Internal/Execution/RootScopeState.swift
Sources/Lattice/Internal/Execution/ApplyAction.swift
Sources/Lattice/Internal/Execution/EmissionExecution.swift
Sources/Lattice/Internal/Execution/RootScopeTasks.swift
Sources/Lattice/Presentation/ViewModel/ViewModel.swift             # becomes production execution owner
Sources/Lattice/Presentation/ViewModel/EventTask.swift             # upgraded to root-scope semantics
Sources/Lattice/Testing/TestViewModel/TestViewModel.swift
Sources/Lattice/Testing/TestViewModel/TestEventTask.swift
Sources/Lattice/Testing/TestViewModel/PendingReceive.swift
Sources/Lattice/Testing/TestViewModel/InFlightEffectRecord.swift
Sources/Lattice/Testing/TestViewModel/RootSendOrigin.swift
Sources/Lattice/Testing/TestViewModel/Exhaustivity.swift
Sources/Lattice/Testing/TestViewModel/TestFailure.swift
Sources/Lattice/Testing/InteractorTestHarness.swift                # delete by end of project
```

Optional support splits if implementation pressure justifies them:

```text
Sources/Lattice/Internal/Execution/AppendExecution.swift
Sources/Lattice/Internal/Execution/ObserveExecution.swift
Sources/Lattice/Internal/Execution/FinishSupport.swift
Sources/Lattice/Testing/TestViewModel/Internal/ReceiveMatching.swift
Sources/Lattice/Testing/TestViewModel/Internal/StateDiffing.swift
Sources/Lattice/Testing/TestViewModel/Internal/TimeoutSupport.swift
```

## Core internal types

The shared execution layer should stay small and concrete.

Core value types:

- `ActionSource`
  - `.sent`
  - `.emitted`
- `SendScopeID`
- `EffectID`
- `BufferedAction<Action>`
- `ActionTransition<State, Action>`
- `RootScopeState`

Core helper functions:

- `applyAction`
  - synchronous interactor mutation helper
- `EmissionExecution.spawnTasks`
  - converts `Emission<Action>` into child tasks and preserves root-scope ownership
- root-scope task support
  - builds `EventTask` / `TestEventTask`
  - waits for quiescence
  - performs cancellation

These helpers:

- should not own visible state
- should not own diagnostics
- should not own pending receives
- should not expose public API
- should not act as a long-lived runtime owner under a new name

## Public API targets

### `ViewModel<F>`

Public production API stays the same:

- `sendViewEvent(_:) -> EventTask`
- eager `viewState` updates
- same `Feature`-driven initialization ergonomics

Internal ownership changes:

- remove stored `FeatureRuntime`
- store buffered action queue directly in `ViewModel`
- store root-scope bookkeeping directly in `ViewModel`
- store effect tasks directly in `ViewModel`
- commit view state inside `ViewModel`, not from a runtime callback

### `EventTask`

`EventTask` remains production-only.

Required semantic change:

- `finish()` waits for root-scope quiescence across recursive emitted work
- `cancel()` cancels the currently tracked tasks for that root scope

### `TestViewModel<F>`

Public testing API remains the destination:

- `send`
- `receive`
- `finish`
- `skipReceivedActions`
- `skipInFlightEffects`
- `exhaustivity`

Internal ownership:

- buffered action queue
- pending receive queue
- in-flight effect tracking
- root-send origin metadata
- effect-start barrier
- state assertion and diagnostics

### `TestEventTask`

`TestEventTask` remains root-scope based:

- async `cancel()`
- timeout-aware `finish()`
- no automatic draining of pending receives

## Behavioral rules

These rules are non-negotiable for the implementation.

### Buffered send loop

Both `ViewModel` and `TestViewModel` must use a buffered internal send loop:

- sent actions enqueue into a queue
- emitted actions re-enqueue into the same queue
- recursive effect output belongs to the same root scope
- execution stays serialized on the main actor

### Root-scope ownership

Every public send starts a root scope.

That root scope owns:

- any immediate effect tasks
- any child work started by emitted actions
- any later tasks started through `.append`

This is what makes production `EventTask.finish()` transitive and makes `TestEventTask.finish()` meaningful.

### Production visibility

`ViewModel` should preserve current behavior:

- sent actions update state immediately
- emitted actions update state immediately
- view state reduces eagerly
- sent actions only reduce view state when state actually changed under the feature's equality rule
- emitted actions reduce view state regardless, as they do today

### Test visibility

`TestViewModel` must keep two views of state:

- `latestState`
  - latest internally reduced domain state
- `assertedState`
  - test-visible domain state

Rules:

- `.sent` transitions update both
- `.emitted` transitions update only `latestState` and queue a `PendingReceive`
- `domainState` reflects the asserted/committed state, not the hidden latest runtime state

### `receive`

`receive`:

- never re-enters execution
- consumes from queued `PendingReceive`
- advances test-visible state to the stored resulting snapshot
- supports exact-action, predicate, and case-path matching

### `finish`

Production:

- `EventTask.finish()` waits for root-scope quiescence

Testing:

- `TestViewModel.finish()` checks unhandled receives first, then waits for effects
- `TestEventTask.finish()` waits for root-scope quiescence only
- neither one auto-drains pending receives

### Effect-start barrier

The old plan used runtime hooks to expose effect-start events.

In the new design:

- `TestViewModel` owns its own effect-start barrier directly
- use `AsyncStream.makeStream` or equivalent local bookkeeping to signal started effects
- do not recreate this as a generic runtime observer surface

### `.append`

`.append` must continue against internal latest state, not test-visible asserted state.

That means:

- the append task belongs to the same root scope
- later emitted child actions keep mutating internal latest state eagerly
- pending receives still gate test-visible advancement

### Cancellation

Cancellation semantics stay aligned with the previous plan:

- stop future emissions
- do not remove already-buffered receives
- cancel current tasks belonging to the relevant root scope

## What not to build

Avoid these shapes even if they seem like easy refactors:

- `FeatureRuntime.Hooks`
- `FeatureRuntimeObserver`
- a production/test mode enum on a shared runtime type
- a replacement central mutable runtime object under another name
- a separate `Driver` abstraction for synchronous interactor mutation
- per-scope waiter registries for `finish()`
- `Task.detached`
- explicit `MainActor.run` hopping inside code that already lives on `@MainActor`

## Implementation phases

### Phase 1: Extract shared execution primitives

Goal:

- move the reusable semantics out of [`FeatureRuntime.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift) into helper files without yet deleting the runtime

Files:

- new `Sources/Lattice/Internal/Execution/*`
- [`FeatureRuntime.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift) may remain temporarily while code moves out

Work:

1. Add `ActionSource`, `SendScopeID`, `EffectID`, `BufferedAction`, `ActionTransition`, and `RootScopeState`.
2. Add `applyAction`.
3. Add emission execution support for `.none`, `.action`, `.perform`, `.observe`, `.merge`, and `.append`.
4. Add root-scope quiescence support for event-task construction.
5. Keep helper APIs internal and concrete.

Acceptance:

- helper-level tests prove emission execution matches current ordering and cancellation semantics
- no public API changes yet

### Phase 2: Make `ViewModel` the production execution owner

Status: completed on April 14, 2026.

Goal:

- move execution ownership out of `FeatureRuntime` and into [`ViewModel.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/ViewModel.swift)

Files:

- [`ViewModel.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/ViewModel.swift)
- [`EventTask.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/EventTask.swift)

Work:

1. Remove the stored `FeatureRuntime`.
2. Store domain state, buffered actions, root scopes, and effect tasks directly in `ViewModel`.
3. Inline the production send loop into `ViewModel`.
4. Commit view-state updates directly in `ViewModel`.
5. Upgrade `EventTask` to root-scope semantics.

Acceptance:

- existing production `ViewModel` tests pass unchanged
- eager view-state updates remain correct
- recursive emitted work is covered by `EventTask.finish()`

### Phase 3: Add `TestViewModel` on the same helper semantics

Goal:

- build the testing API as a first-class owner, not as a coordinator above a runtime

Files:

- `Sources/Lattice/Testing/TestViewModel/*`

Work:

1. Implement the test-owned buffered send loop.
2. Add `pendingReceives`.
3. Add in-flight effect tracking and root-send origin metadata.
4. Add the effect-start barrier directly in `TestViewModel`.
5. Implement `send`, `receive`, `finish`, `skipReceivedActions`, and `skipInFlightEffects`.
6. Add exact-action, predicate, and case-path receive overloads.
7. Add diagnostics and diffing helpers.

Acceptance:

- `TestViewModel` matches the intended TCA-style send / receive / finish semantics
- pending receives stay queued until explicitly handled or skipped
- diagnostics are actionable and specific

### Phase 4: Delete `FeatureRuntime`

Status: completed on April 14, 2026.

Goal:

- remove the obsolete shared runtime owner entirely

Files:

- [`FeatureRuntime.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift)
- any temporary bridging code

Work:

1. Delete the runtime type.
2. Remove any remaining references from `ViewModel`, tests, and support code.
3. Delete [`EffectTaskRegistry.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/EffectTaskRegistry.swift) if it no longer has a coherent standalone role.

Acceptance:

- `rg -n "FeatureRuntime" Sources Tests ExampleProject` only finds intentional historical/spec references

### Phase 5: Replace harness tests and delete the harness

Status: completed on April 14, 2026.

Goal:

- complete the clean-break migration away from [`InteractorTestHarness.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift)

Files:

- harness-based tests
- [`InteractorTestHarness.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift)

Work:

1. Port async, append, observe, hot-stream, and cancellation tests to `TestViewModel`.
2. Remove ad hoc `Task.yield()` / `Task.sleep()` settling where the new design makes it unnecessary.
3. Delete the harness.

Acceptance:

- `rg -n "InteractorTestHarness" README.md Sources Tests ExampleProject` is empty except for intentional historical/spec references
- timing-sensitive tests no longer depend on ad hoc settling

### Phase 6: Docs and examples

Goal:

- make the new testing lane and ownership model the documented story

Files:

- [`README.md`](/Users/michaelbattaglia/Documents/lattice/lattice/README.md)
- [`specs/feature-runtime/README.md`](/Users/michaelbattaglia/Documents/lattice/lattice/specs/feature-runtime/README.md)
- [`specs/feature-runtime/feature-runtime-update-plan.md`](/Users/michaelbattaglia/Documents/lattice/lattice/specs/feature-runtime/feature-runtime-update-plan.md)

Work:

1. Remove hooks/coordinator language from docs.
2. Present `TestViewModel<F>` as the only testing lane.
3. Document the ownership-collapsed design and root-scope semantics.

Acceptance:

- docs no longer describe hooks as the intended design

## Test matrix

New or updated suites should cover:

- helper-level execution semantics for `.perform`, `.observe`, `.merge`, `.append`, and recursive emissions
- `ViewModel` execution ownership
- `EventTask` root-scope finish/cancel behavior
- `TestViewModelSendTests`
- `TestViewModelReceiveTests`
- `TestViewModelFinishTests`
- `TestViewModelExhaustivityTests`
- `TestViewModelFailureTests`
- `TestViewModelAppendTests`
- `TestViewModelObserveTests`
- `TestViewModelCancellationTests`

Existing suites that must stay green:

- [`ViewModelTests.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/PresentationTests/ViewModelTests.swift)
- [`ViewModelAppendTests.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/PresentationTests/ViewModelAppendTests.swift)
- [`AsyncCounterInteractorTests.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/DomainTests/InteractorTests/CounterInteractors/AsyncCounterInteractorTests.swift)
- [`HotCounterInteractorTests.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/DomainTests/InteractorTests/CounterInteractors/HotCounterInteractorTests.swift)
- debounce and observe-focused suites

Focused verification commands:

```bash
swift test --filter ViewModel
swift test --filter EventTaskTests
swift test --filter TestViewModel
swift test --filter Append
swift test --filter Observe
swift test
```

## Clean break from `InteractorTestHarness`

There is still no compatibility period for the old harness.

The implementation is only complete when all three are true:

1. `TestViewModel<F>` exists and covers the required semantics.
2. Harness-based library tests have been ported.
3. [`InteractorTestHarness.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift) is deleted.

Replacement recipe for interactor-style tests:

```swift
let feature = Feature(
    interactor: CounterInteractor(),
    reducer: BuildViewState<CounterState, CounterState> { domainState, viewState in
        viewState = domainState
    }
)

let model = TestViewModel(
    initialDomainState: CounterState(),
    feature: feature
)
```

If a tiny internal helper makes those migrations less repetitive after the clean-break migration, add it then. Do not make it public.

## Diagnostics

Diagnostics are part of the public testing feature, not cleanup work.

Must-have categories:

1. Must handle received actions before sending another action.
2. Unexpected received actions left unhandled at `finish()` / teardown.
3. Expected to receive action, but none arrived before timeout.
4. Received unexpected action before this one.
5. Expected effects to finish, but some remain in flight.
6. Skipped received actions.
7. Skipped in-flight effects.
8. State mutation did not match expectation.
9. Assertion closure made no changes when a change was expected.

Diagnostics belong in:

- `TestViewModel`
- `TestEventTask`
- internal diffing/matching helpers

Diagnostics do not belong in:

- shared production execution helpers
- any replacement for `FeatureRuntime`

## Autonomous work packets

Packet A: shared execution primitives

- Owns action application, emission execution, root-scope bookkeeping, and shared finish/cancellation support.
- Verification: helper-focused execution tests.

Packet B: production ownership collapse

- Owns `ViewModel` execution, production view-state commits, and upgraded `EventTask`.
- Verification: existing `ViewModel` suites plus new `EventTask` tests.

Packet C: public testing API

- Owns `TestViewModel`, `TestEventTask`, pending receives, in-flight effect tracking, diagnostics, and receive overloads.
- Verification: `TestViewModel*` suites.

Packet D: clean-break migration and docs

- Ports harness-based tests.
- Deletes the harness and runtime leftovers.
- Updates docs/specs.
- Verification: full `swift test`.

## Recommended PR breakdown

1. `extract-shared-execution-primitives`
2. `move-production-execution-into-viewmodel`
3. `add-testviewmodel-and-testeventtask`
4. `delete-featureruntime-and-old-registry`
5. `replace-harness-tests-and-remove-harness`
6. `docs-and-spec-cleanup`

Notes:

- PRs 1 through 3 can land before the final clean-break deletions.
- The work is not complete until PR 5 removes the harness and PR 4 removes the runtime owner.
- Do not add a deprecation-only PR.

## Risks

### Risk 1: semantic drift between production and test execution owners

Mitigation:

- share action application and emission execution helpers
- duplicate only visibility policy and public API behavior

### Risk 2: replacing `FeatureRuntime` with another central mutable owner under a different name

Mitigation:

- keep shared code helper-shaped
- do not reintroduce a long-lived observable engine

### Risk 3: shallow root-scope bookkeeping

Mitigation:

- root scopes must own recursive child work transitively
- `finish()` semantics should be defined in terms of root-scope quiescence, not only directly spawned tasks

### Risk 4: over-abstracting the no-hooks design

Mitigation:

- avoid observer protocols, weak callback registries, and generic coordination hubs
- accept a small amount of top-level send-loop duplication in `ViewModel` and `TestViewModel` if it keeps ownership obvious

### Risk 5: timeout-heavy tests surviving the migration

Mitigation:

- use direct root-scope and effect-start bookkeeping in `TestViewModel`
- do not rely on retrospective history arrays or ad hoc settling as the primary testing story

## Final recommendation

Ship the ownership collapse described in [`feature-runtime-update-plan.md`](/Users/michaelbattaglia/Documents/lattice/lattice/specs/feature-runtime/feature-runtime-update-plan.md).

That is the cleanest way to preserve the good parts of the original runtime extraction while removing the hooks smell:

- shared semantics stay shared
- ownership becomes explicit
- production stays eager
- testing gets real send/receive semantics
- `EventTask` becomes meaningfully transitive
- `InteractorTestHarness` still exits as part of the finished work

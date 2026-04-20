# ViewModel Event Loop And Emission Handling

This document describes the production execution loop behind `ViewModel.sendViewEvent(_:)`: how actions are buffered, how the interactor is applied, how effects are scheduled, and what `EventTask` actually waits for.

Key source files:

- [ViewModel.swift](../Sources/Lattice/Presentation/ViewModel/ViewModel.swift)
- [Emission.swift](../Sources/Lattice/Domain/Emission.swift)
- [EmissionExecution.swift](../Sources/Lattice/Internal/Execution/EmissionExecution.swift)
- [ApplyAction.swift](../Sources/Lattice/Internal/Execution/ApplyAction.swift)
- [RootScopeState.swift](../Sources/Lattice/Internal/Execution/RootScopeState.swift)
- [RootScopeTasks.swift](../Sources/Lattice/Internal/Execution/RootScopeTasks.swift)

## Core Execution Model

Production execution is FIFO and root-scope based.

- Every `sendViewEvent(_:)` call creates a fresh `SendScopeID`.
- The initial action is buffered as `.sent`.
- Any later action emitted from an effect is buffered as `.emitted` in that same root scope.
- `ViewModel` drains one shared deque of buffered actions and uses `isSending` to prevent unsafe re-entrant drains.

This buffering is internal. It is not the same as `TestViewModel`'s visible receive buffer.

## Step-By-Step Loop

For each buffered action, `ViewModel` does the following:

1. Pop the next buffered action from the front of the deque.
2. Decrement that root scope's `bufferedActionCount`.
3. Copy the current domain state into a working value.
4. Apply the interactor synchronously through `ActionTransition.apply(...)`.
5. Commit the transition into production state.
6. Spawn effect work from the returned `Emission<Action>`.
7. Prune the root scope if it is now quiescent.

`ActionTransition` carries the action, source, previous state, current state, emission, and root scope. See [ActionTransition.swift](../Sources/Lattice/Internal/Execution/ActionTransition.swift).

## Commit Rules

Committing a transition does two separate things:

- Replace the stored production `domainState`.
- Decide whether to re-run the `ViewStateReducer`.

The reducer rules are:

- Sent action: reduce only if `areStatesEqual(previousState, currentState)` is false.
- Emitted action: always reduce.

That means an emitted action can refresh presentation even when the custom equality function treats the domain state as unchanged.

## Root Send Scopes

Root scopes are tracked in `rootScopes: OrderedDictionary<SendScopeID, RootScopeState>`.

Each scope records:

- `bufferedActionCount`
- `inFlightEffectIDs`

A scope is quiescent only when both reach zero.

This is what `EventTask.finish()` waits on. It is not a general "all work in the app" wait. It is scoped to the send that started the work and to all descendant work emitted from it.

## Emission Kinds

`Emission<Action>` has six runtime forms:

- `.none`
- `.action`
- `.perform`
- `.observe`
- `.merge`
- `.append`

The event loop delegates their scheduling to `EmissionExecution.spawnTasks(...)`.

## `.action`

`.action` is synchronous from the event loop's point of view.

- No tracked effect task is created.
- The action is immediately re-enqueued into the same root scope.
- The buffered-action drain continues through the normal queue.

## `.perform`

`.perform` creates one tracked task.

- The task awaits the work closure.
- If the closure returns `nil`, no action is emitted.
- If the task is cancelled before delivery, nothing is re-enqueued.
- If the closure returns a non-`nil` action and the task is still active, that action is enqueued back into the same root scope.

Debounced `.perform` work uses the same model with an extra sleep/cancellation layer coordinated by `EffectCancellationRegistry`.

## `.observe`

`.observe` creates one tracked task that iterates an `AsyncStream<Action>`.

- Each yielded action is re-enqueued into the same root scope.
- The task stays in flight until the stream finishes or is cancelled.

This is how long-lived observations participate in the same completion and cancellation model as one-shot effects.

## `.merge`

`.merge` spawns each child emission concurrently.

- Child tasks are tracked independently.
- All children share the same root scope.
- The root scope stays non-quiescent until every child task and any descendant work finish.

`Merge` and `MergeMany` interactor composition relies on this behavior.

## `.append`

`.append` is sequential.

There are two layers to its behavior:

- Structural normalization happens when the value is built: nested `.append` values are flattened, `.none` children are dropped, and empty or single-child results collapse.
- Runtime scheduling creates one tracked parent task that executes child emissions one step at a time.

For each child emission, the parent task:

1. Spawns the child emission.
2. Collects the resulting child tasks.
3. Waits for those child tasks before moving to the next appended step.

That is why `.append(.observe(...), .perform(...))` waits for the observation to finish before starting the later perform, and why `.append(.merge(...), next)` waits for the whole merge before moving on.

## Cancellation

`EventTask.cancel()` cancels the root-scope task produced by `RootScopeTasks.makeTask(...)`.

Cancellation works by:

1. Triggering the scope's `cancelScope` callback.
2. Canceling all currently tracked in-flight effect tasks in that root scope.
3. Waiting until the scope becomes quiescent.

Important details:

- Cancellation targets currently tracked effect work, not already-buffered actions.
- Appended work stops at the current step; later steps never start.
- Child work emitted from the same root scope is included.

## Debounce Handling

Lattice supports debouncing in two places:

- `Emission.debounce(using:)` wraps `.perform` emissions and recursively applies to `.merge` and `.append` children while leaving `.observe` unchanged.
- `Interactors.Debounce` debounces only top-level `.perform` child emissions and treats top-level `.observe`, `.merge`, and `.append` as programmer errors.

Debounce replacement is coordinated through `EffectCancellationRegistry`, which swaps the currently pending task for a debounce token and cancels the older one.

## EventTask Completion Semantics

`EventTask.finish()` waits for root-scope quiescence.

That includes:

- All buffered actions in the scope being drained.
- All in-flight effect tasks in the scope being completed or cancelled.
- Any descendant work started by emitted actions.

It does not include work from unrelated sends.

## Production Vs Test Buffering

Production `ViewModel` buffering is an internal serialization tool. Emitted actions are applied as soon as the runtime drains them.

`TestViewModel` is different:

- Emitted actions are still reduced internally.
- Their resulting states are held in a visible pending-receive queue.
- Tests must explicitly `receive(...)` or skip them.

That difference is central to understanding why production UI updates happen automatically while tests remain step-wise.

## Related Specs

- [ViewModel](./view-model.md)
- [Interactors](./interactors.md)
- [Testing Infrastructure](./testing-infrastructure.md)

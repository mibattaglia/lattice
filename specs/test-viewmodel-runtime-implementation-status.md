# TestViewModel Runtime Implementation Status

Status: working checklist synthesized from:
- [TestViewModel: Feature-First Testing Runtime](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md)
- [TestViewModel Runtime Alignment with TCA Themes](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md)

This document tracks the major implementation tasks across both plans and marks their current status in the codebase.

Status legend:
- `done`: implemented in the current codebase
- `partial`: present, but not yet in the shape described by the plans
- `todo`: not implemented yet

## Runtime foundation

- `done` Shared internal runtime used by production and test facades
  Current code: `FeatureRuntime` exists and is used by both `ViewModel` and `TestViewModel`.
  Refs: [test-viewmodel-testing-runtime.md:58](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:58), [test-viewmodel-testing-runtime.md:450](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:450), [test-viewmodel-testing-runtime.md:759](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:759), [test-viewmodel-runtime-tca-alignment.md:130](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:130)

- `done` Origin-scoped task tracking for spawned async work
  Current code: `EffectTaskRegistry` tracks tasks by `originID`.
  Refs: [test-viewmodel-testing-runtime.md:414](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:414), [test-viewmodel-testing-runtime.md:424](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:424), [test-viewmodel-runtime-tca-alignment.md:193](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:193)

- `done` Runtime finish API for a single origin and full runtime drain
  Current code: `FeatureRuntime.finish(originID:timeout:)` and `FeatureRuntime.finish(timeout:)`.
  Refs: [test-viewmodel-testing-runtime.md:360](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:360), [test-viewmodel-testing-runtime.md:475](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:475), [test-viewmodel-runtime-tca-alignment.md:172](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:172)

- `todo` Buffered root send loop
  Plan intent: one root loop buffers actions and processes them without recursive user-level sending.
  Current gap: `FeatureRuntime.send` still mutates state immediately and recursively feeds `.action` emissions back into `send`.
  Refs: [test-viewmodel-runtime-tca-alignment.md:40](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:40), [test-viewmodel-runtime-tca-alignment.md:178](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:178), [test-viewmodel-runtime-tca-alignment.md:224](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:224), [test-viewmodel-runtime-tca-alignment.md:749](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:749)

- `todo` Reentrant user-send guard
  Plan intent: user-origin sends should not reenter the synchronous send wave.
  Current gap: there is no `isSending` or buffered action queue in `FeatureRuntime`.
  Refs: [test-viewmodel-runtime-tca-alignment.md:48](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:48), [test-viewmodel-runtime-tca-alignment.md:316](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:316), [test-viewmodel-runtime-tca-alignment.md:730](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:730)

- `todo` Local-state reduction wave with one commit at the end of send
  Plan intent: reduce through a local `currentState` during the synchronous send wave.
  Current gap: `FeatureRuntime.send` mutates `state` directly.
  Refs: [test-viewmodel-runtime-tca-alignment.md:48](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:48), [test-viewmodel-runtime-tca-alignment.md:274](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:274)

## Emission execution

- `done` `.perform` execution in shared runtime
  Refs: [test-viewmodel-testing-runtime.md:72](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:72), [test-viewmodel-testing-runtime.md:438](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:438)
- `done` `.observe` execution in shared runtime
  Refs: [test-viewmodel-testing-runtime.md:72](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:72), [test-viewmodel-testing-runtime.md:440](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:440)
- `done` `.merge` execution in shared runtime
  Refs: [test-viewmodel-testing-runtime.md:72](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:72), [test-viewmodel-testing-runtime.md:441](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:441)
- `done` `.append` execution in shared runtime
  Refs: [test-viewmodel-testing-runtime.md:72](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:72), [test-viewmodel-testing-runtime.md:442](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:442), [test-viewmodel-runtime-tca-alignment.md:447](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:447)

- `partial` `.append` support is implemented but still sequences via origin-wide in-flight counting
  Plan intent: direct child completion should drive sequencing.
  Current gap: `.append` waits for `waitForOriginEmissionCount(originID, targetCount: 1)`.
  Refs: [test-viewmodel-runtime-tca-alignment.md:447](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:447), [test-viewmodel-runtime-tca-alignment.md:752](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:752)

- `todo` Deterministic startup registration for async emissions
  Plan intent: `send` should return only after immediate async emissions have been registered and `.observe` subscriptions have started.
  Current gap: `.observe` starts a task and awaits the stream inside it, but there is no explicit subscription-start boundary exposed to tests.
  Refs: [test-viewmodel-testing-runtime.md:432](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:432), [test-viewmodel-runtime-tca-alignment.md:183](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:183), [test-viewmodel-runtime-tca-alignment.md:325](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:325), [test-viewmodel-runtime-tca-alignment.md:732](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:732)

- `todo` Feature-owned cancellation identities in `Emission`
  Plan intent: `Emission.cancellable(id:cancelInFlight:)` and `.cancel(id:)`.
  Current gap: cancellation is still origin/task-handle based rather than part of the emission model.
  Refs: [test-viewmodel-runtime-tca-alignment.md:119](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:119), [test-viewmodel-runtime-tca-alignment.md:374](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:374), [test-viewmodel-runtime-tca-alignment.md:743](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:743)

## Production facade

- `done` `ViewModel` is a thin facade over `FeatureRuntime`
  Refs: [test-viewmodel-runtime-tca-alignment.md:57](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:57)
- `done` `EventTask` remains a thin task handle returned from production sends
  Refs: [test-viewmodel-testing-runtime.md:37](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:37), [test-viewmodel-runtime-tca-alignment.md:198](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:198), [test-viewmodel-runtime-tca-alignment.md:764](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:764)

- `partial` View-state reduction is driven from runtime steps, but the presentation rule is duplicated inline
  Plan intent: use one shared helper for presentation relevance.
  Current gap: `ViewModel` computes `step.source == .emitted || !areStatesEqual(...)` inline.
  Refs: [test-viewmodel-runtime-tca-alignment.md:611](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:611), [test-viewmodel-runtime-tca-alignment.md:704](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:704)

## Test facade

- `done` Public `TestViewModel<F>` type exists
  Refs: [test-viewmodel-testing-runtime.md:45](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:45), [test-viewmodel-testing-runtime.md:70](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:70), [test-viewmodel-testing-runtime.md:783](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:783)
- `done` Public `TestEventTask` type exists
  Refs: [test-viewmodel-testing-runtime.md:73](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:73), [test-viewmodel-testing-runtime.md:171](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:171), [test-viewmodel-testing-runtime.md:892](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:892)
- `done` `TestViewModel.send` asserts immediate state mutation
  Refs: [test-viewmodel-testing-runtime.md:53](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:53), [test-viewmodel-testing-runtime.md:334](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:334), [test-viewmodel-runtime-tca-alignment.md:214](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:214)
- `done` `TestViewModel.receive` asserts buffered received actions
  Refs: [test-viewmodel-testing-runtime.md:55](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:55), [test-viewmodel-testing-runtime.md:348](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:348), [test-viewmodel-runtime-tca-alignment.md:552](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:552)
- `done` `TestViewModel.finish` first fails if buffered received actions remain, then waits for in-flight emissions
  Refs: [test-viewmodel-testing-runtime.md:360](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:360), [test-viewmodel-runtime-tca-alignment.md:214](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:214), [test-viewmodel-runtime-tca-alignment.md:739](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:739)
- `done` `skipReceivedActions` exists
  Refs: [test-viewmodel-testing-runtime.md:369](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:369)
- `done` `skipInFlightEffects` exists
  Refs: [test-viewmodel-testing-runtime.md:377](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:377), [test-viewmodel-runtime-tca-alignment.md:577](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:577)
- `done` Exhaustivity mode exists with `.on` and `.off(showSkippedAssertions:)`
  Refs: [test-viewmodel-testing-runtime.md:638](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:638), [test-viewmodel-runtime-tca-alignment.md:86](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:86)

- `done` Received actions from emissions are buffered as distinct test-runtime items
  Current code: `ReceivedStep` stores action, domain state, view state, and origin.
  Refs: [test-viewmodel-testing-runtime.md:391](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:391), [test-viewmodel-runtime-tca-alignment.md:70](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:70), [test-viewmodel-runtime-tca-alignment.md:552](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:552)

- `done` Sent-step snapshots are tracked separately from received-step buffering
  Current code: `SentStepSnapshot` stores the post-send domain/view snapshot for sent actions.
  Refs: [test-viewmodel-testing-runtime.md:488](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:488), [test-viewmodel-runtime-tca-alignment.md:214](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:214)

- `partial` Non-exhaustive mode can skip buffered receives, but `receive` does not yet match later buffered items
  Plan intent: non-exhaustive `receive` may skip earlier buffered actions while matching a later one.
  Current gap: `receive` only checks the first buffered action.
  Refs: [test-viewmodel-runtime-tca-alignment.md:569](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:569), [test-viewmodel-runtime-tca-alignment.md:740](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:740)

- `partial` `skipInFlightEffects` exists, but its semantics are destructive cancellation
  Plan intent: either align with bookkeeping-only skipping or rename to reflect cancellation.
  Current gap: `skipInFlightEffects` currently calls `taskRegistry.cancelAll()`.
  Refs: [test-viewmodel-testing-runtime.md:379](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:379), [test-viewmodel-runtime-tca-alignment.md:577](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:577), [test-viewmodel-runtime-tca-alignment.md:753](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:753)

- `todo` Replace polling/yielding in `TestViewModel.send`
  Plan intent: explicit runtime synchronization instead of `Task.yield()`.
  Current gap: `send` still yields when emissions start.
  Refs: [test-viewmodel-testing-runtime.md:343](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:343), [test-viewmodel-testing-runtime.md:444](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:444), [test-viewmodel-testing-runtime.md:916](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:916), [test-viewmodel-runtime-tca-alignment.md:494](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:494), [test-viewmodel-runtime-tca-alignment.md:736](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:736)

- `todo` Replace polling/yielding in `TestViewModel.receive`
  Plan intent: explicit wait channels / continuations instead of polling.
  Current gap: `nextReceivedStep` still loops with `Task.yield()` until timeout.
  Refs: [test-viewmodel-testing-runtime.md:352](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:352), [test-viewmodel-runtime-tca-alignment.md:494](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:494), [test-viewmodel-runtime-tca-alignment.md:737](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:737)

## Presentation semantics

- `partial` Production and test facades both apply the same presentation rule today, but each computes it independently
  Current code:
  - `ViewModel` computes it inline
  - `TestViewModel.handle(step:)` computes it inline
  Refs: [test-viewmodel-testing-runtime.md:611](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:611), [test-viewmodel-runtime-tca-alignment.md:611](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:611)

- `todo` Shared `shouldReducePresentation(...)` helper on the runtime
  Plan intent: centralize the presentation-relevance rule without introducing a second callback stream.
  Refs: [test-viewmodel-runtime-tca-alignment.md:621](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:621), [test-viewmodel-runtime-tca-alignment.md:702](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:702), [test-viewmodel-runtime-tca-alignment.md:754](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:754)

## Testing and coverage

- `done` Test coverage exists for immediate sends, async received buffering, append ordering, cancellation, debounce, and non-exhaustive skipping
  Current tests: `Tests/LatticeTests/TestingInfrastructureTests/TestViewModelTests.swift`
  Refs: [test-viewmodel-testing-runtime.md:923](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:923), [test-viewmodel-testing-runtime.md:1001](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:1001)

- `done` Append-specific coverage exists in both domain/runtime and presentation tests
  Refs: [test-viewmodel-testing-runtime.md:1008](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:1008), [test-viewmodel-runtime-tca-alignment.md:733](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:733)

- `partial` Existing tests validate the current runtime shape, not the revised buffered-root-loop design
  Plan intent: once the runtime rewrite lands, tests should be updated or expanded to validate the new send/receive boundaries directly.
  Refs: [test-viewmodel-runtime-tca-alignment.md:728](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:728), [test-viewmodel-runtime-tca-alignment.md:747](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:747)

## Recommended implementation order

These steps reflect the current combined plan, in execution order:

1. `todo` Land the buffered root send loop in `FeatureRuntime`.
   Refs: [test-viewmodel-runtime-tca-alignment.md:224](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:224), [test-viewmodel-runtime-tca-alignment.md:749](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:749)
2. `todo` Add reentrant user-send guards.
   Refs: [test-viewmodel-runtime-tca-alignment.md:48](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:48), [test-viewmodel-runtime-tca-alignment.md:730](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:730)
3. `todo` Replace test-layer polling with explicit runtime synchronization.
   Refs: [test-viewmodel-runtime-tca-alignment.md:494](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:494), [test-viewmodel-runtime-tca-alignment.md:750](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:750)
4. `todo` Rework `.append` sequencing to use direct child completion.
   Refs: [test-viewmodel-runtime-tca-alignment.md:447](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:447), [test-viewmodel-runtime-tca-alignment.md:752](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:752)
5. `todo` Add emission cancellation identities to `Emission`.
   Refs: [test-viewmodel-runtime-tca-alignment.md:374](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:374), [test-viewmodel-runtime-tca-alignment.md:751](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:751)
6. `todo` Centralize presentation relevance with a shared runtime helper.
   Refs: [test-viewmodel-runtime-tca-alignment.md:611](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:611), [test-viewmodel-runtime-tca-alignment.md:754](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:754)
7. `todo` Decide whether `skipInFlightEffects` should remain destructive or be renamed / changed to bookkeeping-only behavior.
   Refs: [test-viewmodel-testing-runtime.md:377](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md:377), [test-viewmodel-runtime-tca-alignment.md:577](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:577), [test-viewmodel-runtime-tca-alignment.md:753](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md:753)

## Snapshot summary

- `done` Core shared runtime/test-facade architecture exists.
- `done` `TestViewModel` is real and covered by tests.
- `partial` Exhaustivity and received-action buffering are substantially in place.
- `partial` `.append` works, but uses the older origin-count sequencing model.
- `todo` The main runtime rewrite from the newer alignment plan has not happened yet.

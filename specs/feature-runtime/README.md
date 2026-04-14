# FeatureRuntime Research

This document is the source-backed research brief for the next breaking testing redesign.

It is intentionally shorter and more citation-heavy than the existing design draft at [specs/test-viewmodel-testing-runtime.md](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md). That older document is useful as a proposal; this one is meant to anchor future implementation plans in what Lattice and TCA actually do today.

## Research question

How should Lattice evolve its existing shared `FeatureRuntime<State, Action>` so that:

- production `ViewModel` keeps its current `Feature`-driven ergonomics and eager `viewState` updates;
- a future `TestViewModel<F>` can expose TCA-like step-wise `send`/`receive` assertions;
- effect startup, buffering, completion, and cancellation become deterministic enough that consumers no longer need ad hoc `Task.yield()` and `Task.sleep()` to make tests settle?

## Short answer

Lattice does not need a brand-new shared runtime. It already has one.

- `ViewModel` delegates action execution to `FeatureRuntime` and derives `viewState` from runtime steps [ViewModel.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/ViewModel.swift#L78) (L78-L215).
- `InteractorTestHarness` also delegates to the same `FeatureRuntime`, but only records retrospective state/action history [InteractorTestHarness.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift#L63) (L63-L240).

The actual gap is semantic, not structural:

- current `FeatureRuntime` immediately feeds emitted actions back into the system instead of buffering them for test-time `receive` assertions [FeatureRuntime.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift#L83) (L83-L154);
- effect tracking is a bag of raw `Task<Void, Never>` values with no origin metadata, no pending-receive queue, and no effect-start signal beyond task creation [FeatureRuntime.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift#L52) (L52-L76), [EffectTaskRegistry.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/EffectTaskRegistry.swift#L3) (L3-L31);
- the public test surface is retrospective (`assertStates`, `assertActions`) rather than step-wise [InteractorTestHarness.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift#L169) (L169-L229).

## Current Lattice findings

### 0. The repo is already aligned around feature-first APIs

- `FeatureProtocol` and `Feature<Action, DomainState, ViewState>` already package the interactor, view-state reducer, initial view-state factory, and state equality strategy into a single feature value [Feature.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/Feature/Feature.swift#L7) (L7-L112).
- Public `ViewModel` is already feature-typed (`ViewModel<F>`) rather than generic over action/state/view-state separately [ViewModel.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/ViewModel.swift#L78) (L78-L107).
- That means a future `TestViewModel<F>` would not be introducing a new architectural lane; it would be extending the current public `Feature`-first direction already captured in [specs/feature-only-viewmodel-breaking-plan.md](/Users/michaelbattaglia/Documents/lattice/lattice/specs/feature-only-viewmodel-breaking-plan.md#L3) (L3-L81) and [specs/test-viewmodel-testing-runtime.md](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md#L3) (L3-L79).

### 1. Production `ViewModel` already runs through a shared runtime

- `ViewModel<F>` stores a `FeatureRuntime<DomainState, Action>` and registers a step handler to reduce `viewState` whenever runtime state changes or an emitted action is processed [ViewModel.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/ViewModel.swift#L83) (L83-L134).
- `sendViewEvent(_:)` is a thin forwarder to `runtime.send(event)` [ViewModel.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/ViewModel.swift#L204) (L204-L210).
- `EventTask` is only a wrapper around an optional raw task. It can `cancel`, `finish`, and report `hasEffects`, but it does not encode effect identity, buffered actions, or assertion semantics [EventTask.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/EventTask.swift#L40) (L40-L65).

### 2. `FeatureRuntime` is production-oriented

- `send` mutates state synchronously through the interactor, invokes `onStep`, spawns tasks from the returned `Emission`, and wraps them in a composite `EventTask` [FeatureRuntime.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift#L38) (L38-L76).
- `.action` emissions recurse immediately via `send(action, source: .emitted)` rather than becoming test-observable queued receives [FeatureRuntime.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift#L88) (L88-L90).
- `.perform` and `.observe` also immediately loop back into `send(..., source: .emitted)` on the main actor as soon as work produces an action [FeatureRuntime.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift#L92) (L92-L115).
- `.append` is serialized by awaiting child tasks in order, but the runtime still only tracks raw tasks, not logical effect lifecycle or emitted-action checkpoints [FeatureRuntime.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift#L122) (L122-L154).

### 3. The current test API is retrospective

- `InteractorTestHarness` also uses `FeatureRuntime`, but the only test-facing data it accumulates is `stateHistory` and `actionHistory` via the runtime step callback [InteractorTestHarness.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift#L80) (L80-L112).
- Tests assert after the fact with `assertStates`, `assertLatestState`, and `assertActions`; there is no first-class `receive` step or exhaustivity model [InteractorTestHarness.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift#L169) (L169-L229).
- Because emitted actions are already processed before they are recorded, a harness user cannot naturally express "send X, then receive Y, then assert the next mutation." The history arrays only show that those things happened.

### 4. Timing sensitivity currently leaks into tests

These are the most direct examples in the current Lattice suite:

- `AsyncCounterInteractorTests` still performs `await Task.yield()` after `await harness.send(.asyncIncrement).finish()` before sending the next action [AsyncCounterInteractorTests.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/DomainTests/InteractorTests/CounterInteractors/AsyncCounterInteractorTests.swift#L10) (L10-L27).
- `HotCounterInteractorTests` uses real `Task.sleep` delays to let `CurrentValueSubject` emissions propagate before asserting on the harness [HotCounterInteractorTests.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/DomainTests/InteractorTests/CounterInteractors/HotCounterInteractorTests.swift#L19) (L19-L30).
- Append tests in both presentation and testing infrastructure are marked `.serialized` and use `Task.sleep` in effect bodies and cancellation checks [ViewModelAppendTests.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/PresentationTests/ViewModelAppendTests.swift#L6) (L6-L133), [InteractorTestHarnessAppendTests.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/TestingInfrastructureTests/InteractorTestHarnessAppendTests.swift#L5) (L5-L105).
- Even the sample async presentation interactor uses a real `Task.sleep` inside `.perform`, which is fine for a toy test but reinforces timeout-based patterns instead of clock-driven determinism [MyInteractor.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/PresentationTests/Mocks/MyInteractor.swift#L34) (L34-L41).

There are also legitimate time-based utilities in the library:

- `Debouncer` sleeps on an injected `Clock`, which is the correct kind of time dependency for deterministic tests [Debouncer.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/Debouncer.swift#L47) (L47-L69).
- `Emission.debounce(using:)` preserves that injected-clock path [Emission+Debounce.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Domain/Emission+Debounce.swift#L29) (L29-L60).
- `AsyncStreamRecorder` still implements waiting via timeout plus `Task.sleep`, which is useful as a helper but is not strong enough to define the main feature-testing story [AsyncStreamRecorder.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/AsyncStreamRecorder.swift#L86) (L86-L120).

### 5. What is missing for a real `TestViewModel`

The existing runtime extraction is helpful, but it is not yet the right abstraction boundary for a TCA-like test API:

| Concern | Lattice today | Why it blocks `TestViewModel` |
| --- | --- | --- |
| Sent vs effect-emitted actions | Only encoded as `Step.source`, after the action has already been applied [FeatureRuntime.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift#L5) (L5-L15) | Tests need effect outputs buffered before they mutate test-visible state |
| Effect tracking | `EffectTaskRegistry` stores raw tasks by `UUID` only [EffectTaskRegistry.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/EffectTaskRegistry.swift#L3) (L3-L31) | Tests need logical effects, origin metadata, and in-flight status |
| Receive API | None | Cannot express TCA-style `await model.receive(...)` |
| Exhaustivity | None | Tests can accidentally leave unhandled effect output behind |
| Diagnostics | Assertion errors are plain strings on final history arrays [InteractorTestHarness.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift#L176) (L176-L237) | Missing actionable failure modes like “must handle received action before sending another action” |
| View state timing | `ViewModel` eagerly reduces `viewState` on every emitted step [ViewModel.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/ViewModel.swift#L127) (L127-L134) | A test wrapper around live `ViewModel` would lose the chance to assert intermediate receives |

### 6. `EventTask.finish()` is probably not transitive enough for test use

- `FeatureRuntime.send` builds its returned `EventTask` from the tasks directly spawned by the current emission [FeatureRuntime.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift#L52) (L52-L76).
- But `.action`, `.perform`, and `.observe` all call back into `send(..., source: .emitted)` and discard the returned `EventTask` [FeatureRuntime.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift#L88) (L88-L115).
- Inference: `EventTask.finish()` guarantees completion of the work directly started by the original send, but not necessarily the full downstream effect tree started by actions emitted from that work.
- That behavior is acceptable for production UI flows, but it is not strong enough for a future `TestEventTask` that needs exhaustivity, timeout semantics, and deterministic `finish()` behavior across chained emissions.

## TCA findings

### 1. Consumer ergonomics are intentionally step-wise

- The README teaches `TestStore` as a user-flow tool: `await store.send(...) { ... }`, then `await store.receive(...) { ... }` for effect output [README.md](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/README.md#L318) (L318-L355).
- The `TestStore` docs make exhaustive testing the default contract: every sent action must assert state changes, every effect-emitted action must be explicitly received, and all effects must finish by the end of the test [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L10) (L10-L45).
- Example tests read like event traces rather than history snapshots, including effect sequencing and state snapshots after each receive [TestStoreTests.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Tests/ComposableArchitectureTests/TestStoreTests.swift#L54) (L54-L121).

### 2. `TestStore.send` waits for effect startup, not effect completion

- TCA explicitly documents that `send` suspends only until the effect starts; long-running work is represented by the returned `TestStoreTask` [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L846) (L846-L883).
- `send` refuses to proceed when there are unhandled received actions, preserving causal ordering in tests [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L904) (L904-L919).
- After sending, TCA waits for subscription startup through either `Task.yield()` or an explicit `effectDidSubscribe` stream, then performs additional `Task.megaYield` work so users do not need to instrument tests manually [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L942) (L942-L980).

### 3. `receive` is backed by a queue of effect outputs

- `receive(_:)` first waits for a matching effect-emitted action when effects are still in flight, then asserts how state changed from that receive [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L1295) (L1295-L1358).
- The core receive path dequeues from `receivedActions`, validates ordering, and compares the expected post-receive state snapshot [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L1734) (L1734-L1839).
- Waiting for receives is separated from asserting receives; the timeout path produces a targeted diagnostic depending on whether there are in-flight effects that could still deliver the action [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L1842) (L1842-L1898).

### 4. TCA's test runtime tracks logical effects, not just tasks

- `TestReducer` wraps the reducer under test and distinguishes `.send` actions from `.receive` actions in a dedicated `TestAction` enum [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L2348) (L2348-L2461).
- Effect outputs are not applied immediately to the test store's visible state. Instead, the reducer records `(action, state)` pairs into `receivedActions` when processing `.receive` actions [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L2380) (L2380-L2388).
- `receiveAction` then advances the test-visible state by dequeuing buffered entries from `receivedActions`; in non-exhaustive mode it can intentionally skip buffered entries while still updating visible state to the skipped snapshot [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L1752) (L1752-L1840), [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L2038) (L2038-L2098).
- In-flight effects are tracked as logical `LongLivingEffect` values with source-location metadata from the originating action [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L2395) (L2395-L2423).
- `TestStoreTask` adds async cancellation and timeout-aware `finish()` semantics rather than exposing a raw task directly [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L2252) (L2252-L2345).

### 5. Diagnostics are part of the feature, not a side effect

- TCA has explicit failure cases for “must handle received actions before sending another action,” “unexpected action left unhandled,” and “effects still in flight at test completion” [TestStoreFailureTests.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Tests/ComposableArchitectureTests/TestStoreFailureTests.swift#L123) (L123-L222), [TestStoreFailureTests.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Tests/ComposableArchitectureTests/TestStoreFailureTests.swift#L224) (L224-L240).
- `finish()` and deinit both enforce exhaustivity and produce actionable guidance rather than silent hangs or retrospective array mismatches [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L566) (L566-L667).
- Exhaustivity is configurable rather than hard-coded: `on`, `off`, and `off(showSkippedAssertions:)` [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L2464) (L2464-L2498).

## What Lattice should copy from TCA, and what it should not

### Copy

- Step-wise `send` and `receive` as the primary consumer testing language.
- A buffered queue of effect-emitted actions.
- Strong separation between “action was sent” and “effect output was received.”
- Explicit in-flight effect tracking with logical identity and origin metadata.
- Exhaustive-by-default completion rules.
- Helpful timeout and exhaustivity diagnostics.
- A task type for tests that can `cancel` and `finish` with timeout semantics.

### Do not copy literally

- TCA's reducer DSL or dependency system.
- TCA's exact `TestReducer` wrapper shape.
- TCA's case-key-path heavy surface as a baseline requirement.
- TCA-specific shared-state tracking or navigation dismissal machinery.

Lattice should preserve its own architecture lane:

- tests should be feature-first around `Feature`, not reducer-first;
- domain state should remain the primary assertion surface;
- view state should still be derived through `ViewStateReducer`, not stored as the primary source of truth;
- `TestViewModel` should stay focused on domain-state assertions; pure `ViewStateReducer` behavior should be tested in isolation rather than becoming a primary lane of feature-runtime testing;
- runtime extraction should serve both production `ViewModel` and test `TestViewModel` without forcing Lattice to become a reducer/store framework.

## Synthesis: what the next `FeatureRuntime` must become

The next shared runtime should expose a stronger internal contract than today's `send + Step callback + raw tasks`.

Minimum requirements:

- A mode or façade boundary that distinguishes production eager state publication from test buffered-receive publication.
- Runtime events for:
  - sent action accepted;
  - synchronous state mutation finished;
  - effect subscribed/started;
  - effect emitted action;
  - effect completed;
  - effect cancelled.
- A pending-receive queue that stores enough information for test assertions.
  - At minimum: action, previous domain state snapshot, resulting domain state snapshot, effect origin, and source location if available.
- Logical effect tracking separate from raw `Task` handles.
- A startup barrier so `send` does not return before immediate effects are registered.
- A test-facing task abstraction with timeout-aware `finish` and async `cancel`, and with explicit semantics for downstream work started by emitted actions.
- Exhaustive completion checks for pending receives and in-flight effects.

This leads to a likely layering:

1. `FeatureRuntime`
   - owns domain state mutation, emission interpretation, effect registration, buffering, and lifecycle events.
2. `ViewModel`
   - subscribes to runtime state/step events and eagerly reduces `viewState`.
   - in production mode, emitted actions are drained automatically.
3. `TestViewModel`
   - drives the same runtime in buffered mode.
   - exposes `send`, `receive`, `finish`, and exhaustivity controls for domain-state testing.
   - does not need inline view-state assertion APIs as a primary design goal.
4. `InteractorTestHarness`
   - should be removed entirely by the end of the project.
   - library tests and examples should be migrated to `TestViewModel`.

## Implications for future planning

The next implementation plan should start from these assumptions:

- "Extract a shared runtime" is already partially done in the repo; phase 1 should be described as "upgrade the existing runtime contract."
- The critical design choice is where buffering lives: in a lower-level engine, or in a test-oriented façade that lets emitted actions continue to run while withholding those transitions from test-visible state until `receive`.
- The runtime needs effect-start observability. Without it, tests will keep compensating with `Task.yield()` and `Task.sleep()`.
- `EventTask` is sufficient for production UI workflows, but not as the foundation for the testing API, especially if `finish()` remains non-transitive over downstream emitted work.
- The testing story should stay domain-state-first. `ViewStateReducer` remains a pure unit that can be tested separately without making view-state assertions part of the core `TestViewModel` contract.
- `InteractorTestHarness` is not the target end-state. The project should finish with library tests and examples updated to `TestViewModel`, and `InteractorTestHarness` removed.
- A future plan should treat diagnostics as part of the public API, not as cleanup work.

## Resolved directions

- Lattice should mimic TCA's layering here using Lattice terminology and patterns:
  - keep `FeatureRuntime` as the low-level production execution engine;
  - put buffered test-visible behavior in a thin internal test coordinator or façade above that engine;
  - do not contort production `ViewModel` or other public production APIs to facilitate testing.
- `TestViewModel.domainState` should reflect the last asserted or committed state, not the latest internally reduced state hidden behind pending receives.
- `TestViewModel` should remain domain-state-first. `viewState` should not be a primary assertion lane for the feature runtime, and pure `ViewStateReducer` behavior should be tested separately.
- v1 diagnostics should preserve only high-value metadata:
  - originating action;
  - whether the action path was sent or emitted;
  - a logical effect ID;
  - the public test callsite (`fileID`, `filePath`, `line`, `column`).
- v1 should ship exhaustive-by-default semantics first.
  - If `skipReceivedActions` and `skipInFlightEffects` fall out naturally from the runtime design, include them.
  - A richer public non-exhaustive mode can follow after the core exhaustive model is stable.

## Source index

Lattice

- [ViewModel.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/ViewModel.swift#L78)
- [Feature.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/Feature/Feature.swift#L7)
- [FeatureRuntime.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift#L4)
- [InteractorTestHarness.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift#L63)
- [EventTask.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/EventTask.swift#L40)
- [EffectTaskRegistry.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/EffectTaskRegistry.swift#L3)
- [AsyncStreamRecorder.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/AsyncStreamRecorder.swift#L36)
- [Debouncer.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/Debouncer.swift#L20)
- [Emission+Debounce.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Domain/Emission+Debounce.swift#L3)
- [AsyncCounterInteractorTests.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/DomainTests/InteractorTests/CounterInteractors/AsyncCounterInteractorTests.swift#L10)
- [HotCounterInteractorTests.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/DomainTests/InteractorTests/CounterInteractors/HotCounterInteractorTests.swift#L11)
- [ViewModelAppendTests.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/PresentationTests/ViewModelAppendTests.swift#L6)
- [InteractorTestHarnessAppendTests.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/TestingInfrastructureTests/InteractorTestHarnessAppendTests.swift#L5)
- [MyInteractor.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/PresentationTests/Mocks/MyInteractor.swift#L12)

TCA

- [README.md](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/README.md#L318)
- [TestingTCA.md](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Documentation.docc/Articles/TestingTCA.md#L15)
- [Store.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Store.swift#L155)
- [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift#L10)
- [TestStoreTests.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Tests/ComposableArchitectureTests/TestStoreTests.swift#L54)
- [TestStoreFailureTests.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Tests/ComposableArchitectureTests/TestStoreFailureTests.swift#L123)

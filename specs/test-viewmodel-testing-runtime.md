# TestViewModel: Feature-First Testing Runtime

## Goal

Replace `InteractorTestHarness` as the primary public testing tool with a feature-first `TestViewModel` that:

- tests Lattice features through `Feature`, not bare interactors;
- provides deterministic async and concurrency behavior;
- supports step-wise assertions over sent and effect-emitted actions;
- makes domain state assertions the primary lane;
- still exposes view state for targeted validation;
- aligns with the strengths of TCA's `TestStore` without forcing Lattice into TCA's reducer model.

## Why

Lattice's current testing surface is useful for basic interactor tests, but it has structural problems:

1. `InteractorTestHarness` is retrospective.
   - Tests usually send several actions and then compare full `stateHistory` or `actionHistory`.
   - This is brittle because failures happen at the end, after the runtime has already advanced through multiple steps.

2. It has weak concurrency semantics.
   - Several tests rely on `Task.sleep`, `Task.yield`, or serialized suites to make async work settle.
   - This is a sign that the runtime is not giving tests a strong enough synchronization boundary.

3. It duplicates production runtime logic.
   - `InteractorTestHarness` and `ViewModel` both contain nearly identical effect-running logic.
   - That duplication invites drift and makes bug fixes harder to land consistently.

4. It does not model received actions as first-class test events.
   - Effect-emitted actions are immediately fed back into the system and only recorded after the fact in history arrays.
   - Tests cannot naturally express "send this action, then receive that action, then assert the next state change".

5. `EventTask` is not a strong enough test abstraction.
   - Production `EventTask` is fine for UI workflows.
   - In tests, we need stronger lifecycle guarantees, especially around task start, task completion, cancellation, and transitive work triggered by downstream actions.

The result is a testing model that works for simple synchronous cases but gets awkward and fragile as soon as effects, observation, debouncing, or chained emissions enter the picture.

## Core Direction

1. Public tests should be feature-first.
   - The main public testing type should be `TestViewModel<F: FeatureProtocol>`.
   - The test surface should accept the same `Feature` value that production `ViewModel` uses.

2. Domain state should be the primary assertion surface.
   - Tests should primarily describe how domain state changes.
   - View state should remain observable and assertable, but it should not be the default lane for most tests.

3. Test execution must be step-wise and exhaustive by default.
   - `send` should assert immediate state mutation.
   - `receive` should assert effect-emitted actions and their resulting state changes.
   - Tests should fail if they leave behind unexpected received actions or in-flight effects.

4. Production and test runtimes should share as much machinery as possible.
   - Lattice should stop maintaining two copies of effect execution behavior.
   - Shared runtime logic should live in an internal engine, while public types expose production or test-oriented APIs.

5. `InteractorTestHarness` should stop being the strategic API.
   - It may remain temporarily as a migration shim or internal-only escape hatch.
   - It should not be the end state for library consumers.

## Scope

### In scope

- A new `TestViewModel<F>` public testing API.
- Exhaustive-by-default step-wise testing semantics.
- Deterministic handling of `.perform`, `.observe`, `.merge`, `.append`, and debounced effects.
- A dedicated test task type with better lifecycle semantics than `EventTask`.
- Internal runtime extraction to reduce duplication with `ViewModel`.
- Migration guidance away from `InteractorTestHarness`.

### Out of scope

- A broad dependency system redesign.
- Replacing `TestClock` or the current clock-based testing story.
- Requiring all production features to opt into new macros.
- Forcing all internal low-level runtime tests to immediately become `TestViewModel` tests.

## Implementation Phases

- [x] Phase 1: Extract the shared emission/effect runtime used by `ViewModel` and `InteractorTestHarness`.
  - Landed: internal `EmissionRuntime` now owns `.action`, `.perform`, `.observe`, `.merge`, and `.append` execution for both facades, and regression coverage was added for `ViewModel` append sequencing.
- [ ] Phase 2: Introduce buffered received-step storage and test-mode runtime behavior.
- [ ] Phase 3: Add the public `TestViewModel<F>` and `TestEventTask` APIs with exhaustive `send` / `receive` / `finish`.
- [ ] Phase 4: Migrate and expand tests/docs toward the new feature-first surface.

## Desired Public API

```swift
@MainActor
public final class TestViewModel<F: FeatureProtocol> {
    public typealias Action = F.Action
    public typealias DomainState = F.DomainState
    public typealias ViewState = F.ViewState

    public enum Exhaustivity: Sendable {
        case on
        case off(showSkippedAssertions: Bool = false)
    }

    public var domainState: DomainState { get }
    public var viewState: ViewState { get }
    public var exhaustivity: Exhaustivity

    public init(
        initialDomainState: DomainState,
        feature: F,
        timeout: Duration = .seconds(1)
    )

    @discardableResult
    public func send(
        _ action: Action,
        assert updateExpectedState: ((_ state: inout DomainState) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestEventTask

    public func receive(
        _ expectedAction: Action,
        timeout: Duration? = nil,
        assert updateExpectedState: ((_ state: inout DomainState) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async where Action: Equatable

    public func receive(
        _ isMatching: (Action) -> Bool,
        timeout: Duration? = nil,
        assert updateExpectedState: ((_ state: inout DomainState) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async

    public func finish(
        timeout: Duration? = nil,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async

    public func skipReceivedActions(
        strict: Bool = true,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async

    public func skipInFlightEffects(
        strict: Bool = true,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async

    public func assertViewState(
        _ expected: ViewState,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) where ViewState: Equatable
}

public struct TestEventTask: Sendable {
    public func cancel() async
    public func finish(
        timeout: Duration? = nil,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async
    public var isCancelled: Bool { get }
}
```

## Usage Examples

### 1. Synchronous state change

```swift
@MainActor
@Test
func counter() async {
    let feature = Feature(interactor: CounterInteractor())
    let model = TestViewModel(
        initialDomainState: CounterState(count: 0),
        feature: feature
    )

    await model.send(.increment) {
        $0.count = 1
    }

    await model.send(.decrement) {
        $0.count = 0
    }
}
```

### 2. Async effect round-trip

```swift
@MainActor
@Test
func fetchData() async {
    let feature = Feature(
        interactor: MyInteractor(dateFactory: { Date(timeIntervalSince1970: 0) }),
        reducer: MyViewStateReducer()
    )

    let model = TestViewModel(
        initialDomainState: .loading,
        feature: feature
    )

    await model.send(.load) {
        $0 = .success(.init(count: 0, timestamp: 0, isLoading: false))
    }

    await model.send(.fetchData) {
        $0.modify(\.success) { $0.isLoading = true }
    }

    await model.receive(.fetchDataCompleted(42)) {
        $0.modify(\.success) {
            $0.isLoading = false
            $0.count = 42
        }
    }

    await model.finish()
}
```

### 3. Debounced effect with `TestClock`

```swift
@MainActor
@Test
func debounce() async {
    let clock = TestClock()
    let feature = SearchFeature(clock: clock)

    let model = TestViewModel(
        initialDomainState: SearchFeature.State(),
        feature: feature
    )

    await model.send(.queryChanged("s")) {
        $0.query = "s"
    }

    await model.send(.queryChanged("sw")) {
        $0.query = "sw"
    }

    await model.send(.queryChanged("swift")) {
        $0.query = "swift"
    }

    await clock.advance(by: .milliseconds(300))

    await model.receive(.searchResponse(["Swift"])) {
        $0.results = ["Swift"]
    }

    await model.finish()
}
```

### 4. Long-living observation

```swift
@MainActor
@Test
func observationLifecycle() async {
    let feature = CounterStreamFeature()
    let model = TestViewModel(
        initialDomainState: .init(count: 0),
        feature: feature
    )

    let observeTask = await model.send(.startObserving)

    await model.receive(.valueUpdated(1)) {
        $0.count = 1
    }

    await model.receive(.valueUpdated(2)) {
        $0.count = 2
    }

    await observeTask.cancel()
    await model.finish()
}
```

### 5. Optional view-state assertion

```swift
@MainActor
@Test
func viewStateProjection() async {
    let feature = Feature(
        interactor: ProfileInteractor(),
        reducer: ProfileViewStateReducer()
    )

    let model = TestViewModel(
        initialDomainState: .loading,
        feature: feature
    )

    await model.send(.loadCompleted(.init(name: "Blob"))) {
        $0 = .loaded(.init(name: "Blob"))
    }

    model.assertViewState(.loaded(name: "Blob"))
}
```

## Assertion Model

The biggest behavioral shift from `InteractorTestHarness` is that assertions become step-wise rather than retrospective.

### `send`

`send` should:

1. Fail if there are unhandled received actions and exhaustivity is on.
2. Apply the sent action to the currently asserted domain state.
3. Compare actual state mutation against the trailing `assert` closure.
4. Commit the new asserted state and derived view state.
5. Start any resulting effects.
6. Suspend long enough for effect subscriptions to begin.
7. Return a `TestEventTask` representing the lifecycle of the effect tree rooted at this send.

Important: `send` should not wait for effects to finish. It should only wait until the runtime has fully registered any new work spawned by the action.

### `receive`

`receive` should:

1. Wait for a queued effect-emitted action matching the expectation.
2. Assert that the action arrived in the expected order.
3. Compare the queued post-reduce state snapshot against the trailing `assert` closure.
4. Commit that queued snapshot as the new asserted state and view state.
5. Keep exhaustivity guarantees intact.

This is the central semantic missing from `InteractorTestHarness`.

### `finish`

`finish` should:

1. Report unexpected queued actions if any remain unhandled.
2. Wait for all in-flight effects to drain.
3. Fail with actionable diagnostics if work is still in flight after the timeout.
4. Verify the runtime is fully settled before the test exits.

### `skipReceivedActions`

This should be the non-exhaustive escape hatch for queued effect actions:

- if strict, fail when there is nothing to skip;
- advance the asserted state/view state to the latest queued snapshot;
- clear queued actions.

### `skipInFlightEffects`

This should:

- cancel all currently tracked in-flight effects;
- await their cancellation;
- serve as the explicit escape hatch for long-living effects when exhaustive testing is not wanted.

## Runtime Semantics

`TestViewModel` cannot just wrap a live `ViewModel` instance.

If it did, effect-emitted actions would immediately mutate visible state and view state before the test had a chance to call `receive`. That would destroy the step-wise model and reintroduce brittleness.

Instead, test execution should run in a dedicated runtime mode with two concepts of state:

1. Asserted state
   - The current state the test has explicitly acknowledged.
   - Exposed via `domainState` and `viewState`.

2. Buffered received states
   - Post-reduce snapshots created by effect-emitted actions.
   - Held in a queue until the test calls `receive` or skips them.

Each queued entry should contain:

```swift
struct ReceivedStep<State, ViewState, Action> {
    let action: Action
    let domainState: State
    let viewState: ViewState
    let originID: UUID
}
```

This buffered model is what makes exhaustive testing possible.

## Task and Effect Tracking

The test runtime should track:

- in-flight effects;
- the origin action that started each effect tree;
- effect subscription/start events;
- queued received actions;
- timeouts and diagnostics.

### Effect origin tracking

Each `send` should allocate an `originID`.

Any action emitted by effects downstream of that send should preserve the same `originID`, and any additional effects spawned by those actions should inherit it. This gives `TestEventTask` a stable unit to wait on or cancel.

Without origin tracking, a task returned by `send` can only describe the first wave of effects, not the full transitive tree kicked off by the action.

### Effect start boundary

One source of flakiness today is that tests sometimes have to guess when an effect has actually started.

`TestViewModel.send` should not return until the runtime has done enough work to register all immediate effects originating from the sent action. That means:

- synchronous `.action` emissions have been reduced;
- `.perform` tasks have been created and registered;
- `.observe` streams have been subscribed;
- `.merge` children have all been registered;
- `.append` has registered its outer coordinator task.

This is the boundary that should eliminate most ad hoc `Task.yield()` calls from tests.

## Shared Runtime Architecture

The recommended implementation shape is:

1. Extract a shared internal runtime core.
2. Keep `ViewModel` as the production facade.
3. Build `TestViewModel` as the testing facade over the same core primitives.

One possible shape:

```swift
@MainActor
final class FeatureRuntime<State, ViewState, Action> {
    var assertedDomainState: State
    var assertedViewState: ViewState

    var receivedSteps: [ReceivedStep<State, ViewState, Action>] = []
    var inFlightEffects: [UUID: TrackedEffect<Action>] = [:]

    func send(_ action: Action, mode: RuntimeMode) async -> RuntimeSendResult
    func receiveNext(matching: (Action) -> Bool, timeout: Duration) async -> ReceivedStep<State, ViewState, Action>?
    func finish(timeout: Duration) async -> FinishResult
}

enum RuntimeMode {
    case live
    case testing
}
```

Production `ViewModel` would use `.live`.

`TestViewModel` would use `.testing`, which buffers received actions and snapshots instead of immediately committing them as externally visible state.

This keeps the logic for effect spawning, cancellation, and composition in one place while allowing production and test surfaces to differ where they need to.

## Domain State vs View State

The spec should be explicit about this:

### Primary lane: domain state

Most tests should assert domain state because:

- it is the source of truth for feature logic;
- it avoids brittle coupling to presentation details;
- it keeps tests focused on the business behavior of the feature.

### Secondary lane: view state

View state still matters when:

- validating a tricky projection;
- validating equality strategy behavior;
- validating user-facing projection bugs;
- validating important intermediate UI states such as loading, empty, disabled, or derived-section states.

But it should be an explicit choice:

```swift
model.assertViewState(expectedViewState)
```

not the default mode for every test.

### Recommended split of responsibilities

The spec should explicitly recommend two lanes:

1. `TestViewModel` for feature integration behavior
   - use it to test action sequencing;
   - use it to test effect behavior;
   - use it to assert domain state step by step;
   - use `assertViewState` at checkpoints when integrated presentation behavior matters.

2. `ViewStateReducer` tests for exhaustive projection coverage
   - use them when the goal is to validate every nook and cranny of how domain state maps to view state;
   - use them when projection logic is the thing under test, not async feature flow;
   - prefer them when integrated feature tests would otherwise become walls of duplicated domain and view assertions.

This gives users a clear answer to "where should I test view state?":

- if the question is about feature flow, use `TestViewModel`;
- if the question is about projection coverage, use `ViewStateReducer` tests.

### View-state assertion timing

Final-only `viewState` assertions are a common case, but they should not be the only supported case.

The intended semantics are:

- after `await model.send(...)` returns, it is safe to assert the immediate post-send `viewState`;
- after `await model.receive(...)` returns, it is safe to assert the post-receive `viewState`;
- buffered effect output should not advance visible `viewState` until the test explicitly handles that step.

So users can write either:

```swift
await model.send(.load) {
    $0.isLoading = true
}
model.assertViewState(.loading)

await model.receive(.response(...)) {
    $0.isLoading = false
    $0.data = ...
}
model.assertViewState(.loaded(...))
```

or simply assert the final `viewState` at the end when intermediate projection states are not relevant.

## Exhaustivity

The default should be strict exhaustivity, modeled after TCA.

### `Exhaustivity.on`

Requires that tests:

- assert all immediate state changes caused by `send`;
- assert all effect-emitted actions through `receive`;
- finish with no queued actions;
- finish with no in-flight effects.

### `Exhaustivity.off(showSkippedAssertions:)`

Allows:

- extra queued actions to be skipped;
- in-flight effects to be skipped;
- partial assertions on larger integration flows.

The `showSkippedAssertions` option should still surface useful diagnostic information for skipped steps without failing the test.

This mode is important, but it should remain secondary. The main ergonomic gain comes from strong default exhaustivity.

## Diagnostics

The new testing surface should fail loudly and specifically.

### Desired diagnostic classes

1. Sending while received actions are unhandled
2. State changed unexpectedly
3. State did not change when the test claimed it would
4. Expected action was not received
5. Received unexpected action
6. Effects still in flight at test end
7. Attempted to skip when there was nothing to skip

### Example failure shapes

```text
Must handle 1 received action before sending another action.

Unhandled actions:
  .fetchDataCompleted(42)
```

```text
Expected effects to finish, but there are still effects in flight after 1 second.

If this feature uses a test clock, advance it so that the effect may complete.
If this is a long-living effect, cancel it explicitly or call skipInFlightEffects().
```

```text
A state change does not match expectation.

  - expected: count = 1
  + actual:   count = 2
```

Exact wording does not need to match TCA, but the standard should be similarly actionable.

## Compatibility and Migration

### Consumer migration target

Library consumers should move from:

```swift
let harness = InteractorTestHarness(
    initialState: CounterState(count: 0),
    interactor: CounterInteractor()
)

harness.send(.increment)
try harness.assertLatestState(.init(count: 1))
```

to:

```swift
let feature = Feature(interactor: CounterInteractor())
let model = TestViewModel(
    initialDomainState: CounterState(count: 0),
    feature: feature
)

await model.send(.increment) {
    $0.count = 1
}
```

### Internal migration reality

Not every current internal test will migrate directly on day one.

Some low-level library tests currently exercise raw interactor behavior without a feature wrapper, and some domain states in tests are not `ObservableState`.

That means the migration should be phased:

1. Publicly introduce `TestViewModel`.
2. Migrate consumer-facing examples and most feature-level tests.
3. Keep a narrow internal-only escape hatch for low-level runtime tests.
4. Deprecate `InteractorTestHarness`.
5. Remove public references to `InteractorTestHarness` from docs.

### About `ObservableState`

This proposal assumes the public testing lane is feature-based, which means it inherits `FeatureProtocol`'s `ViewState: ObservableState` requirement.

For internal tests that only want to probe bare interactor semantics:

- either define a trivial feature wrapper when `DomainState == ViewState` and the state can conform to `ObservableState`;
- or use an internal-only lower-level runtime adapter during migration.

The public API should not bend around these internal transition cases.

## Implementation Plan

### Phase 1: Introduce internal shared runtime

1. Extract effect execution and tracking logic from `ViewModel`.
2. Move runtime responsibilities into an internal shared engine.
3. Preserve current production `ViewModel` behavior.

Acceptance:

- `ViewModel` semantics stay unchanged.
- Effect spawning is no longer duplicated across `ViewModel` and test runtime code.

### Phase 2: Add `TestViewModel`

1. Add `Sources/Lattice/Testing/TestViewModel.swift`.
2. Add `Sources/Lattice/Testing/TestEventTask.swift`.
3. Implement buffered received-action semantics.
4. Add exhaustivity control and timeouts.

Acceptance:

- `send`, `receive`, `finish`, `skipReceivedActions`, and `skipInFlightEffects` all work.
- Tests no longer need manual `Task.yield()` for normal effect startup.

### Phase 3: Migrate focused tests

Start by migrating:

- basic counter tests;
- async effect tests;
- debounced tests;
- long-living observe tests;
- current `ViewModel` tests that already model feature behavior;
- example-package tests under `ExampleProject/`, especially:
  - `ExampleProject/SearchExamplePackage/Tests/`
  - `ExampleProject/TodosExamplePackage/Tests/`

Acceptance:

- New tests exercise real feature semantics through `Feature`.
- Existing flake-prone tests lose raw sleeps/yields where possible.
- Example project tests and sample code reflect the new preferred testing lane.

### Phase 4: Deprecate `InteractorTestHarness`

1. Mark it deprecated in docs and API comments.
2. Remove it from README's preferred testing guidance.
3. Update example project tests and sample code to prefer `TestViewModel`.
4. Keep it only as a temporary compatibility surface if needed.

Acceptance:

- Public guidance points to `TestViewModel`.
- New examples do not use `InteractorTestHarness`.

### Phase 5: DocC and guidance

1. Add DocC documentation for the new testing story.
2. Include explicit guidance on when to use `TestViewModel`.
3. Include explicit guidance on when to test `ViewStateReducer` directly.
4. Include one example that asserts only domain state plus final `viewState`.
5. Include one example that asserts intermediate `viewState` checkpoints after `send` and `receive`.

Recommended docs shape:

- add a new DocC article under a new or existing Lattice DocC bundle;
- if Lattice still has no DocC bundle at that point, introduce `Sources/Lattice/Documentation.docc/`;
- add an article such as `TestingLatticeFeatures.md` or `TestViewModel.md`.

Acceptance:

- Lattice has an official docs page explaining the split between:
  - `TestViewModel` integration tests
  - direct `ViewStateReducer` tests
- examples show both final-only and intermediate `viewState` assertions.

### Phase 6: Cleanup

1. Reassess whether `AsyncStreamRecorder` remains public.
2. Reduce internal runtime duplication further if needed.
3. Remove the harness entirely once migration is complete.

Acceptance:

- Testing story is centered on one public tool.
- Concurrency behavior is deterministic enough that test serialization is reduced.

## Suggested File Changes

New files:

- `Sources/Lattice/Testing/TestViewModel.swift`
- `Sources/Lattice/Testing/TestEventTask.swift`
- one or more new test files covering exhaustive and non-exhaustive behavior
- DocC article(s) under `Sources/Lattice/Documentation.docc/`

Likely refactors:

- `Sources/Lattice/Presentation/ViewModel/ViewModel.swift`
- new internal runtime file(s) under `Sources/Lattice/Internal/`
- `Sources/Lattice/Testing/InteractorTestHarness.swift`
- `README.md`
- tests and sample code under `ExampleProject/`

## Test Plan

Focused tests should cover:

1. synchronous sends;
2. async `.perform` receive flow;
3. `.observe` receive flow;
4. `.merge` fan-out with deterministic receiving;
5. `.append` sequencing;
6. debounced effects with `TestClock`;
7. long-living task cancellation;
8. failure when sending before handling queued actions;
9. failure when leaving effects in flight;
10. non-exhaustive mode behavior.

Suggested commands for the implementation phase:

```bash
swift test --filter ViewModelTests
swift test --filter FeatureViewModelTests
swift test --filter EmissionDebounceTests
swift test --filter DebounceInteractorTests
swift test --filter LatticeTests
```

## Open Questions

1. Should the public property be named `domainState` or just `state`?
   - `domainState` is more explicit next to `viewState`.
   - `state` is shorter and closer to TCA.

2. Should value-based `receive` require `Action: Equatable`, with predicate-based matching as the universal fallback?
   - Recommendation: yes.

3. Should case-path-based `receive` overloads be included in v1?
   - Recommendation: not required for v1, but they are a strong ergonomic follow-up where `Action` is case-pathable.

4. Should `InteractorTestHarness` become a shim over the new test runtime or remain independent during migration?
   - Recommendation: keep migration simple; do not contort the new API around the harness.

5. Should `assertViewState` be enough, or should there also be a closure-based `assertViewState` mutation API?
   - Recommendation: start with direct equality and only add mutation-style assertions if real usage shows need.

## Recommendation

Adopt `TestViewModel<F>` as the new public testing center of gravity.

Do not continue investing in `InteractorTestHarness` as the long-term surface. The main ergonomic gains will come from:

- step-wise `send` and `receive`;
- buffered received-action semantics;
- strict exhaustivity by default;
- a stronger task/effect lifecycle model;
- a shared internal runtime instead of duplicated execution logic.

That direction keeps Lattice's feature-oriented architecture intact while giving consumers a testing experience much closer to what makes TCA's `TestStore` effective.

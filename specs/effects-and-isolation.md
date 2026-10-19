# Effects And Isolation

A feature runs in a `Core`: a nonisolated, non-`Sendable` runtime that holds the state, the interactor, the effects the interactor queued and the effects that are running. A thin isolated shell hosts it, and the core is only ever touched on that shell's isolation, so it needs no locks. Interactors start asynchronous work through an `Effects` handle. Each effect is a task that starts on the shell's isolation, runs until its first suspension before `send` returns, resumes on the shell after every suspension, and delivers its result by modifying state. Nothing in the feature layer has to be `Sendable`.

Key source files:

- [Effects.swift](../Sources/Lattice/Domain/Effects.swift): `Effects`, `EffectOperation`
- [EffectID.swift](../Sources/Lattice/Domain/EffectID.swift)
- [Core.swift](../Sources/Lattice/Internal/Core.swift): `send`, `modify`, auto-cancel, effect start, `invalidate`
- [Task+Immediate.swift](../Sources/Lattice/Internal/Concurrency/Task+Immediate.swift), [StartOnMainActor.swift](../Sources/Lattice/Internal/Concurrency/StartOnMainActor.swift), [DefaultIsolation.swift](../Sources/Lattice/Internal/Concurrency/DefaultIsolation.swift)
- [EnumTag.swift](../Sources/Lattice/Internal/Runtime/EnumTag.swift): the enum tags auto-cancel keys on
- [ViewModel.swift](../Sources/Lattice/Presentation/ViewModel/ViewModel.swift), [ActorModel.swift](../Sources/Lattice/Presentation/ActorModel/ActorModel.swift), [TestHost.swift](../Sources/Lattice/Testing/TestHost.swift)
- [IsolationTests](../Tests/LatticeTests/IsolationTests): `SchedulingTests`, `ModificationTests`, `CoreExitTests`, `ViewModelIsolationTests`, `TestModelIsolationTests`, `ParallelismTests`
- [EffectsTests](../Tests/LatticeTests/DomainTests/EffectsTests): `AutoCancelTests`, `EffectIDTests`; [ActorModelTests](../Tests/LatticeTests/PresentationTests/ActorModelTests); [PresentationTests](../Tests/LatticeTests/PresentationTests): `ModificationObservationTests`, `ViewModelTeardownTests`
- [Tests/NegativeCompileChecks/Effects.swift](../Tests/NegativeCompileChecks/Effects.swift) and [negative-compile-checks.sh](../scripts/negative-compile-checks.sh)

## Core And Shells

| Shell | Kind | The core's isolation | Availability |
|---|---|---|---|
| `ViewModel` | `@MainActor` class, for SwiftUI | `MainActor.shared` | iOS 17, macOS 14, watchOS 10 |
| `ActorModel` | actor, for features off the main actor | its own `DefaultIsolation`, which is also the actor's executor | iOS 26, macOS 26, watchOS 26 |
| `TestModel` | actor, the primary test shell | its own `DefaultIsolation`, through `TestHost` | iOS 26, macOS 26, watchOS 26 |
| `TestViewModel` | `@MainActor` class, for main-actor-isolated interactors | `MainActor.shared`, through `TestHost` | iOS 17, macOS 14, watchOS 10 |

- The core stores its isolation as a plain `any Actor`, bound once at construction. In the library only the shells bind one: `ViewModel` and `TestViewModel` bind `MainActor.shared`, and `ActorModel` and `TestModel` each bind a new `DefaultIsolation`.
- `DefaultIsolation` is an internal, file-scope, non-generic actor. The actor shells forward `unownedExecutor` to it, so their methods and their effects share one serial executor. It is a separate object because binding the shell itself would make `shell → core → isolation` a retain cycle, and the shell's `isolated deinit` would never run.
- The core owns the `ObservationRegistrar` that the coarse `\.state` key path fires on; see [ViewModel](./view-model.md#reading-state).
- Effect tasks hold the core weakly, so the core lives exactly as long as its shell.
- The only runtime isolation check is at effect start. Effects are created inside `isolation.assumeIsolated`, which traps when a send that starts an effect runs off the core's isolation (`CoreExitTests`). A send that starts no effect is not checked. Every shell method is isolated to the core's isolation, so the trap is unreachable through a shell.

## Handling An Action

`Core.send(_:)` is behind `sendViewEvent(_:)`, `ActorModel.send(_:)`, the test shells' `send` and `effects.send`. It is synchronous:

```text
send(action)
  guard not invalidated, not inside interact, not inside modify      else report, return nil
  var working = committed state
  interactor.interact(state: &working, action: action, effects)      perform only queues; each When hop visits a child path
  commit(working)                                                    commit rules, below
  cancel the anonymous effects tracked at every visited path         auto-cancel
  didCommit(action, state)                                           test hook (TestHost)
  start the queued effects, in order                                 assumeIsolated { Task.immediateIfAvailable { … } }
  return the task for the effects this send started                  nil when it started none
```

What follows from this order:

- The interactor mutates a working copy whose `@FeatureState` registrars are shared with the committed value. Member notifications fire during `interact`, and an observer that re-reads the model synchronously sees the previous committed value, with no exclusivity trap.
- The commit keeps the current value when the result is a content-equal wholesale replacement, by the feature's `areStatesEqual`. Otherwise it stores the result, and it fires the coarse `\.state` only when the root `_$id` changed. See [ViewModel](./view-model.md#commit-rules).
- `perform` only queues. An effect starts after `interact` has returned (its `defer`s included), in `perform` order.
- Each effect runs its synchronous preamble, everything up to its first real suspension, before `send` returns. A preamble modification has already been committed when `sendViewEvent(_:)` returns, and an effect that never suspends has already finished.
- A send from a preamble is processed at once, depth-first. The nested action is handled and its effects' preambles run, then the outer preamble continues, then the outer send starts its next effect.
- The start phase works on a snapshot of the queue, so a nested send starts only its own effects. A preamble that re-sends its own case cancels the effects of that case that have already started, itself included, but not the outer send's effects that have not started yet.
- There is no action queue. `effects.send` called during `interact` is reported, returns `nil` and changes nothing. To follow an action with another one, send it from an effect: `effects.perform { try effects.send(.next) }`.

| Guard | Issue | Result |
|---|---|---|
| The model was invalidated | `Can't send <action> to an invalidated model` | `nil` |
| A send while `interact` runs | `Can't send another action before handling this one; use effects.perform { try effects.send(action) }` | `nil`, state untouched |
| A send inside a `modify` body | `Can't send <action> inside 'modify'; dropped` | `nil` |

## The `Effects` Handle

`interact(state:action:effects:)` receives an `Effects<State, Action>`: a value type over closures into the core. It is not `Sendable` and never needs to be, because it is only used on the shell's isolation. Its public surface:

```swift
public typealias EffectOperation = nonisolated(nonsending) () async throws -> Void

public struct Effects<State, Action> {
    public var state: State { get }
    @available(*, noasync)
    public func perform(id: EffectID.Key? = nil, _ operation: @escaping EffectOperation)
    public func modify(_ body: (inout State) -> Void) throws(CancellationError)
    @discardableResult
    public func send(_ action: Action) throws(CancellationError) -> Task<Void, Never>?
    public func cancel(_ id: EffectID.Key)
    public func isRunning(_ id: EffectID.Key) -> Bool
}
```

A typical effect:

```swift
@Interactor<ProfileState, ProfileAction>
struct ProfileInteractor {
    @EffectID var load
    let client: ProfileClient

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .task:
                state.isLoading = true
                effects.perform(id: load) {
                    defer { try? effects.modify { $0.isLoading = false } }  // also runs when cancelled
                    do {
                        let profile = try await client.fetch()
                        try effects.modify { $0.profile = profile }
                    } catch {
                        try Task.checkCancellation()  // cancelled: write no error state
                        try effects.modify { $0.errorMessage = "\(error)" }
                    }
                }
            case .cancelTapped:
                effects.cancel(load)
            }
        }
    }
}
```

The `defer` runs on every path, cancelled or not. A run that is replaced or auto-cancelled runs it after its replacement has started, so a flag shared by consecutive runs can be cleared early: here, a second `.task` replaces the first load, and the first load's `defer` sets `isLoading` to `false` while the second load is still running.

| Member | Legal from | Otherwise |
|---|---|---|
| `perform` | `interact` | A compile error in async contexts: `'perform' is unavailable from asynchronous contexts`. From a synchronous escape it is reported and dropped: `'effects.perform' must be called during interact; dropped`, or `Can't perform an effect inside 'modify'; dropped` inside a `modify` body. |
| `state` | an effect | During `interact`: reported (`Read 'effects.state' during interact; use the 'state' argument instead`), and it returns the committed pre-action value. After invalidation, or once a case-scoped child's case is inactive: reported (`Read 'effects.state' after the model was invalidated or the scoped state went away`), and it returns the last known value. |
| `modify` | an effect | During `interact`: `Can't modify state from effects during interact; mutate the 'state' argument instead`, and the body does not run. Inside another `modify` body: `Can't modify state inside another 'modify'; dropped`. For an inactive case-scoped child: `Child effect modified state after its state was removed from the parent; dropped`. After invalidation it throws `CancellationError` (see [Teardown](#teardown)). |
| `send` | an effect | During `interact` or inside a `modify` body: see [Handling An Action](#handling-an-action). For an inactive case-scoped child: `Child effect sent <action> after its state was removed from the parent; dropped`, and it returns `nil`. After invalidation it throws `CancellationError`. |
| `cancel` | anywhere | — |
| `isRunning` | anywhere | — |

### `perform`

- `EffectOperation` is spelled `nonisolated(nonsending)`, so the closure runs on the isolation it starts on, which is the shell's, and resumes there after every suspension, whatever the consumer module's settings. It may capture non-`Sendable` dependencies.
- Without an `id` the effect is anonymous. It is tracked at the handle's enum-tag path and cancelled the next time that path is handled (see [Auto-Cancel](#auto-cancel)).
- With an `id` the effect is identified. Starting it cancels the running effect of the same key in the same scope, and it is cancelled only by `cancel(_:)`, by cancelling the task `send` returned, or by teardown (see [Effect Identity](#effect-identity-effectid)).
- Every anonymous effect of one send is tracked: two `Merge` children that perform for the same action both run.

### `state`

- `effects.state` reads the committed state without registering an observation access on the core.
- Each successful read refreshes the handle's last known value. The value is seeded when the handle is created: the committed state for the root handle of a send, and the child state `When` routed the action to for a child handle.
- It is get-only. Changes go through `modify`.

### `modify`

- `modify` is how an effect delivers its result: no response action is involved.
- Each call is one working copy, one commit through the same rules as `send`, and one test entry (`didCommit` with no action), however many members the body touches. Members changed in place notify only their own observers, and a content-equal replacement notifies nothing.
- A cancelled effect's `modify` is still committed, which is what lets a `defer` clean up after a cancel. A result that a newer action made stale needs a `try Task.checkCancellation()` right before its `modify` (see [Cancellation is cooperative](#cancellation-is-cooperative)).
- Through a `When` handle, the body runs on the child state extracted from the parent, and the result is written back by key-path assignment or case re-embedding: one parent commit. Nested `When`s chain upward.

### `send`

`send` has three jobs, and anything else is a `modify`:

1. starting new effects, because `perform` is legal only during `interact`;
2. running interactor logic, so that a parent, a `Merge` sibling or a `When` can react to the action;
3. auto-cancelling by action case.

The action is processed synchronously and depth-first, with no hop, and `send` returns the task for the effects that action started. A cancelled effect's send is still delivered.

### `cancel` and `isRunning`

- Both act on the handle's scope: the `When` chain that produced it.
- During `interact`, `cancel(_:)` is queued and runs in order in the start phase. It runs after the effects performed before it in the same `interact` have started and before the ones performed after it start. So `effects.cancel(load)` followed by `effects.perform(id: load) { … }` cancels the running load and starts the new one. From an effect, `cancel(_:)` is immediate.
- `isRunning(_:)` is synchronous. It is `true` from the moment the effect is registered, its own preamble included, until its operation returns, it is replaced, or it is cancelled by `cancel(_:)` or teardown. An effect that finishes inside its preamble is not running when `send` returns.
- A cancel queued in the same `interact` is not reflected until the start phase: `cancel(x)` followed by `isRunning(x)` in one `interact` is `true`.
- Cancelling the task `send` returned cancels the effect, but `isRunning` stays `true` until the effect has unwound. The task's cancellation handler runs off the shell's isolation and cannot mark the effect.
- Neither is observable. A view that needs to know whether an effect runs reads explicit state that the interactor sets and the effect clears in a `defer`, because a cancelled effect never reaches the statements after its suspension point.

## Auto-Cancel

### Paths

- Every handle has an enum-tag path: the tag of the root action, then one tag per `When` hop. For `.child(.start)` the root handle's path is `[tag(.child)]` and the child handle's is `[tag(.child), tag(.start)]`.
- A send visits the root path and every child path a `When` routes it into. After the commit, the anonymous effects tracked at every visited path are cancelled, before the new effects start.
- Tags come from the enum's runtime metadata. They are stable per case and independent of payloads (`.search("a")` and `.search("b")` share a path), and they work for `indirect` cases.

| Running | Then sent | Cancelled |
|---|---|---|
| `.search("a")`'s effect | `.search("b")` | the `"a"` effect |
| `.search("a")`'s effect | `.other` | nothing |
| `.child(.start)`'s child effect | `.child(.other)`, or a root `.other` | nothing |
| `.child(.start)`'s child effect | `.child(.start)` | the previous child effect |
| a parent effect performed for `.child(.start)`, at `[tag(.child)]` | any `.child(…)` | the parent effect |
| two `Merge` children's effects for `.go` | `.go` | both |

- A case-path `When` whose case is not active returns before it scopes, so the action does not visit the child path. The child's earlier effects keep running until the case is active and that child case is handled again (`childActionForAnInactiveCaseIsIgnoredAndCancelsNothing`). If the case becomes active again, those effects read and write the new payload, because their handle only checks whether the case is active (`caseScopedChildEffectUsesTheNewPayloadAfterReactivation`).
- A non-enum `Action` has no tag. Every action then shares one path, and any send cancels every anonymous effect of the root handle. `Action` should be an enum; this is documented, not diagnosed.

### Ignored actions still auto-cancel

`send` cancels after every `interact`, whatever the interactor did. An action that a guard ignores still cancels the anonymous effects of its case, and it starts none in their place. There are two remedies:

- Identify the effect with `@EffectID` and `perform(id:)`. An identified effect is never auto-cancelled; only the next effect of its key replaces it. In the Todos example, a toggle the interactor ignores leaves the pending sort alone.
- When the view owns the effect, drop the guard. Re-sending the action then replaces the running effect, so there is never more than one (the TimerLeak and Phase tickers).

A guard on a running flag kept in state does not avoid this, and a `defer` that clears the flag does not fix it: a re-sent action that the guard ignores still cancels the running effect and starts none. Use one of the two remedies.

### Cancellation is cooperative

Cancelling an effect cancels its task. The effect stops at its next cancellation-aware suspension (`Task.sleep`, `clock.sleep`, cancellable APIs). Until then it keeps running: its sends are delivered and its modifications are committed.

That leaves a window after every suspension. When a sleep returns or a dependency answers, the effect has to hop back to the shell, and a send or cancel that lands on the shell first cannot stop the code the effect runs before its next cancellation-aware suspension:

```text
effect                                   shell
try await clock.sleep(for: interval)
  the sleep returns; resume queued       send(.start) → auto-cancel → task.cancel()
resumes: try effects.modify(tick)        the cancelled effect commits one more tick
next clock.sleep throws                  the loop ends
```

- A tick loop gets at most one extra tick, and a load can commit a result that was due.
- When a late result would be wrong, call `try Task.checkCancellation()` right before the `modify` that delivers it. On a serial isolation nothing can land between the check and the commit. It is required after `try?` or `catch`, which turn cancellation into a value (the Search example). It is not needed when the only suspension is a sleep that throws on cancel and every run writes the same guarded value (the Phase load); see [Interactors](./interactors.md#writing-effects).

## Effect Identity: `@EffectID`

```swift
@Interactor<DownloadsState, DownloadsAction>
struct DownloadsInteractor {
    @EffectID var download
    let client: DownloadClient

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .start(let id):
                effects.perform(id: $download.scoped(id)) {  // one effect per row
                    try await client.download(id)
                    try effects.modify { _ = $0.finished.insert(id) }
                }
            case .cancel(let id):
                effects.cancel($download.scoped(id))
            }
        }
    }
}
```

- `@EffectID var name` declares an `EffectID.Key`. The key is the declaration site (`fileID`, `line`, `column`) plus an optional name. `$name.scoped(element)` adds an element, for one effect per row.
- Identified effects are tracked at the pair of the handle's scope path and the key. The scope path has one entry per `When` hop: the key path or case key path the `When` was built with. It does not depend on the action case, so `.cancel` finds the effect `.start` performed.
- Nothing is stored in state, so state's equality, observation and codability are untouched.

Consequences:

- Every instance of the declaring type names the same effect, including the new child instances `body` builds on every action.
- `When(state: \.a) { Child() }` and `When(state: \.b) { Child() }` keep independent effects under the child's one key.
- Two instances of one child type in the same scope, such as `Merge(Child(), Child())` without a `When`, share the key: the second replaces the first.
- Every specialization of a generic interactor shares one key.
- Only a handle in the same scope can cancel or query a key. A parent and a view cannot.
- A key built from a name at a call site is keyed by that call site, so a perform and a cancel written at two sites never match. Build per-element keys from one declaration with `scoped(_:)`.

## The Task `send` Returns

`sendViewEvent(_:)`, `ScopedViewModel.sendViewEvent(_:)`, `ActorModel.send(_:)`, the test shells' `send` and `effects.send` return `Task<Void, Never>?`:

- `nil` when the action started no effect.
- Otherwise a task that waits for exactly the effects that send started. It does not wait for effects started by actions those effects send, including sends made from their preambles (`sendTaskDoesNotCoverTheEffectsOfSendsItsEffectsMake`).
- Cancelling it cancels every effect that send started. On OS 26 the task is a `Task.immediate`, so its cancellation handler is installed before `send` returns and `task?.cancel()` cancels the effects synchronously. Before OS 26 it is a plain `Task`, because it is built in a nonisolated getter where `#isolation` is `nil`, so the main-actor fallback does not apply; the effects are then cancelled only once that task starts.
- Its `isCancelled` reflects only cancelling this task. Auto-cancel, `cancel(_:)` and replacement cancel the effects' own tasks, and this task finishes once they have unwound.
- `await task?.value` is not cancellation-aware: cancelling the waiting task neither ends the wait nor cancels the effects. Await only effects that end by themselves.

A view's `.task` that starts a long-lived effect forwards its own cancellation, so the effect stops when the view goes away:

```swift
.task {
    let ticker = viewModel.sendViewEvent(.startTicking)
    await withTaskCancellationHandler {
        await ticker?.value
    } onCancel: {
        ticker?.cancel()
    }
}
```

Without the handler, `await viewModel.sendViewEvent(.startTicking)?.value` would leave the ticker running until `.startTicking` is sent again or the view model is deallocated. An effect that ends by itself can be awaited directly: `.refreshable { await viewModel.sendViewEvent(.refresh)?.value }`.

## Teardown

Every shell's `isolated deinit` invalidates the core, which cancels every effect and drops the queue. Each deinit carries an `#if swift(<6.4) @_optimize(none)` guard.

- `ViewModel`: released on the main actor, the deinit runs inline, so every effect has been cancelled when the release returns (`ViewModelTeardownTests.deinitCancelsEffectsAndTheirLaterSendAndModifyThrowWithoutAnIssue`). Released elsewhere, it runs as a main-actor job.
- `ActorModel` and `TestModel`: released off the model's executor, as a test or another isolation releases it, the deinit runs later, as a job on that executor, so teardown is asynchronous. A test that observes it waits under a `.timeLimit` for a signal from the effect, as `ActorModelSchedulingTests.deinitCancelsASleepingEffectWhoseLaterSendAndModifyThrowWithoutAnIssue` does.
- `TestModel` and `TestViewModel` first report what no assertion described, as a warning; see [Testing Infrastructure](./testing-infrastructure.md#deinit).
- After invalidation, an effect's `effects.send` and `effects.modify` throw `CancellationError`. They report nothing, because the effect's task is cancelled; through a handle used from anywhere else they also report `Effect sent <action> after the model was invalidated` or `Effect modified state after the model was invalidated`. `effects.state` is reported and returns the last known value, since the core is gone.
- A loop that sleeps with `try?` still ends at teardown, because its next `modify` throws, but it spins after a plain cancel: write `try await clock.sleep(for:)`.

## Thrown Errors

An effect's operation is `async throws`. When it throws:

- A `CancellationError` is not reported.
- Any other error is not reported if the effect's task is cancelled by the time the error leaves the effect, whoever cancelled it and even if the failure happened earlier. The sources are auto-cancel, `cancel(_:)`, replacement by key, teardown, cancelling the task `send` returned, and `skipInFlightEffects` in tests. Cancellation can surface as another error: URLSession throws `URLError(.cancelled)`, and a dependency may throw its own error once it notices.
- The error of a live effect is reported as an issue, `Effect threw: <error>`. That fails the test under Swift Testing and XCTest and is a runtime warning in an app. The issue points at Lattice's `Core.swift`, not at the effect.
- The effect's `defer`s run on every path.

Catch the errors you expect and turn them into state, as the `ProfileInteractor` above does. A `catch` that writes an error state checks for cancellation first, with `try Task.checkCancellation()` or `guard !Task.isCancelled`, not `error is CancellationError`: a cancelled effect's `modify` still commits, and the cancellation may arrive as another error.

## Concurrency Settings

### `NonisolatedNonsendingByDefault`

- The `Lattice` target enables the upcoming feature (`Package.swift`). The test targets do not, because they stand in for consumer modules.
- `EffectOperation` is explicitly `nonisolated(nonsending)`, so effect closures behave the same in every consumer.
- A consumer's own async functions follow that consumer module's setting. In a module without the feature, a plain `func fetch() async` is `@concurrent`. Calling it from an effect on a captured non-`Sendable` dependency is a compile error, `sending 'self.client' risks causing data races`, with the note `sending 'self.client' to @concurrent instance method 'fetch()' risks causing data races between @concurrent code and code in the current isolation context`. On a `Sendable` dependency, or one the effect created itself, it compiles and runs off the shell's isolation. Mark such methods `nonisolated(nonsending)`, as the example packages do, or enable the feature in the consumer module:

  ```swift
  protocol ProfileClient {
      nonisolated(nonsending) func fetch() async throws -> Profile
  }
  ```

- The standard library's `Clock.sleep(for:tolerance:)` and `sleep(until:tolerance:)` are `@concurrent`, so an effect that sleeps through them hops to the global executor and back. `clock.sleep(for:)` binds instead to Lattice's `nonisolated(nonsending)` overload (in a file that imports Lattice): it starts on the effect's isolation, so an `EffectClock` registers the sleep before `send` returns, and it sends every other clock through `sleep(until:tolerance:)`, which still hops. The hop is harmless in production. In tests it is why a sleep spelled another way registers late, which `EffectClock` reports; see [Testing Infrastructure](./testing-infrastructure.md#time).
- Effects run on the shell. CPU-bound work in an effect runs on the main actor under `ViewModel`; move it behind a `@concurrent` function or a dependency with its own executor.
- A helper that receives a non-`Sendable` dependency and builds an `ActorModel` or `TestModel` from it takes the parameter as `sending`; otherwise handing the `Feature` to the actor is a region-isolation error.

### Main-actor interactors

An interactor or `Interact` closure formed in main-actor-isolated code, such as a module with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` or a `@MainActor` context, is a main-actor value. Passing it to `ActorModel` or `TestModel` is a compile error, and a `@MainActor` test cannot pass `TestModel` its closures either (see [Negative compile checks](#negative-compile-checks)). Such features use `ViewModel` and `TestViewModel`. Sharing an executor would not lift this: the checker reasons about isolation domains, not executors.

## Verification

### Negative compile checks

`scripts/negative-compile-checks.sh` runs after `swift build` and compiles `Tests/NegativeCompileChecks` against the built module in two lanes:

- `-typecheck`: the baseline and the `@Domain` and generic-state flags; see [FeatureState](./feature-state.md).
- `-emit-sil -wmo -o /dev/null`: region-isolation diagnostics come only from SIL passes, never from `-typecheck`. This lane prints diagnostics in the LLVM style, one line per error and per note, because a region-isolation error names the isolation domains only in its note.
  - `NO_SENDABLE_BASELINE` must compile with `-warnings-as-errors`: a non-`Sendable` state, action and dependency, the dependency with a `nonisolated(nonsending)` async method, under `ViewModel`.
  - `PERFORM_IN_EFFECT`: `'perform' is unavailable from asynchronous contexts`.
  - `MAINACTOR_INTERACTOR_TO_TESTMODEL`: a main-actor interactor, from a `@MainActor` factory and formed inline in a `@MainActor` test. Both sites are rejected by the note `sending main actor-isolated value of non-Sendable type 'Feature<CounterAction, CounterState>' to actor-isolated initializer 'init(initialState:feature:exhaustivity:timeout:fileID:filePath:line:column:)' risks causing races in between main actor-isolated and actor-isolated uses`. It names the `Feature` value, because that is what `TestModel.init` takes. The inline test's `receive` predicate is rejected by `sending main actor-isolated value of non-Sendable type '(CounterAction) -> Bool' to actor-isolated instance method 'receive(_:timeout:assert:fileID:filePath:line:column:)'`.

### The isolation regression guard

The effect start loop in `Core.startQueued` is the one place that vouches for isolation, and it has to be a `for` loop written directly in the `assumeIsolated` body. If task creation moves into a nested closure (`map`, `forEach`, a helper), the task closure inherits that closure's nonisolated context. `Task.immediate` still starts it synchronously, so preambles look right, but after its first suspension the effect resumes on the global executor, and the compiler says nothing. Tests whose effect literals are written in `@MainActor` code still pass, because the literal is main-actor-isolated by its lexical context. `ViewModelIsolationTests`, `TestModelIsolationTests` and `ActorModelIsolationTests` therefore form the effect literal at file scope, where it is nonisolated, and check the isolation in the preamble, after a cancelled swift-clocks `TestClock.sleep` (a `@concurrent` hop, through the `clock.sleep(for:)` overload's `sleep(until:tolerance:)` branch) and after `Task.yield()`. With the `.map` shape swapped in, they trap. There is deliberately no per-send isolation assertion in `Core.send`.

### Behaviour suites

Apart from the `ActorModel` suites, they drive `TestModel` and assert what the effects record in state, exhaustively; a cancelled effect is one that never completes under an `EffectClock` and `advance`. `TestViewModel` runs the tests that must hold the executor between two statements, a bare `Core` the internals no shell exposes, and `ViewModel` only the tests it is the subject of.

- `SchedulingTests`: preamble before return, `defer` before effect start, depth-first nested sends, the non-transitive send task, 100 re-sent effects that ignore cancellation still delivering their sends and modifications (under `TestViewModel`), the sleep variant losing the cancelled work, the start-phase snapshot, thrown-error reporting, and `inFlightTasks` during a preamble (a bare `Core`).
- `ModificationTests`: the `modify` guards, `perform` and `send` inside a body, `perform` through an escaped handle (under `TestViewModel`), one commit per `modify` and modifications after invalidation (a bare `Core`), and inactive case-scoped children.
- `ModificationObservationTests`: member-only notification, content-equal replacements, and `When` write-back by key path and case path, under `ViewModel`.
- `ViewModelTeardownTests`: what the `ViewModel` deinit does to its effects, and a handle that outlived its view model.
- `AutoCancelTests` and `EffectIDTests`: paths per case and per `When` hop, `Merge`, tag stability, declaration-site keys across rebuilt and generic instances, replacement, queued and immediate cancels, `isRunning`, scope paths and `scoped(_:)`.
- `ActorModelTests`: scheduling, auto-cancel, isolation and teardown under `ActorModel`.
- `ParallelismTests`: two models per actor shell, whose effects report the isolation they run on; the two differ, so the models can run their effects in parallel.

## Limitations

- Interactors run under `ActorModel` and `TestModel` must be nonisolated (see [Main-actor interactors](#main-actor-interactors)).
- Auto-cancel is cooperative: work stops only at cancellation-aware suspension points.
- The task `send` returns is not transitive.
- A modification runs no interactor logic: a parent or `Merge` sibling cannot react to it, and it cannot start effects. Send an action when one must.
- `effects.state` is get-only.
- `ActorModel` and `TestModel` require OS 26 (`Task.immediate`, and actor `isolated deinit`).
- The pre-OS-26 paths, `Task.startOnMainActor` and the main-actor `isolated deinit` back-deployment, are compile-checked at the deployment floors but have never run in the test suites, which have run only on OS 26 and later hosts.

## Related Specs

- [Interactors](./interactors.md)
- [ViewModel](./view-model.md)
- [Testing Infrastructure](./testing-infrastructure.md)
- [FeatureState](./feature-state.md)

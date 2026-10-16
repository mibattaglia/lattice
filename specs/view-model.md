# ViewModel

`ViewModel` is Lattice's production bridge between SwiftUI and a `Feature`. It is a thin `@MainActor` shell over the feature's runtime, a `Core` bound to the main actor: it exposes the state to views through the `State.ViewState` projection and gives views a single entry point for sending actions, `sendViewEvent(_:)`. `ActorModel`, at the end of this document, hosts the same runtime on an actor of its own. How the runtime handles actions and effects is in [Effects And Isolation](./effects-and-isolation.md).

Key source files:

- [ViewModel.swift](../Sources/Lattice/Presentation/ViewModel/ViewModel.swift)
- [Feature.swift](../Sources/Lattice/Presentation/Feature/Feature.swift)
- [ViewModelBinding.swift](../Sources/Lattice/Presentation/ViewModel/ViewModelBinding.swift)
- [ScopedViewModel.swift](../Sources/Lattice/Presentation/ViewModel/ScopedViewModel.swift)
- [ActorModel.swift](../Sources/Lattice/Presentation/ActorModel/ActorModel.swift)
- [Core.swift](../Sources/Lattice/Internal/Core.swift)
- [ViewModelTests.swift](../Tests/LatticeTests/PresentationTests/ViewModelTests.swift), [ViewModelObservationTests.swift](../Tests/LatticeTests/PresentationTests/ViewModelObservationTests.swift), [ViewModelReentrancyTests.swift](../Tests/LatticeTests/PresentationTests/ViewModelReentrancyTests.swift), [ActorModelTests](../Tests/LatticeTests/PresentationTests/ActorModelTests)

## Responsibilities

- Own the feature's `Core`, bound to `MainActor.shared`: the authoritative state, a `@FeatureState` value, and the feature's effects.
- Expose the state to views through `State.ViewState`, so `@Domain` members stay hidden.
- Forward view events to the core with `sendViewEvent(_:)`, and return the task for the effects they started.
- Expose SwiftUI bindings that turn writes into actions, and scopes for child views.
- Cancel every effect when it is deallocated.

## Relationship To Feature

`ViewModel` is parameterized by `F: FeatureProtocol`, which gives it:

- `F.Action` and `F.State`, a `FeatureState` type. Neither has to be `Sendable`.
- A type-erased interactor, `AnyInteractor<State, Action>`.
- An optional state equality, `areStatesEqual: ((State, State) -> Bool)?`.

`Feature(interactor:)` supplies `==` as the equality when the state is `Equatable` and `nil` otherwise. `Feature(interactor:areStatesEqual:)` takes a custom comparison. See [Feature.swift](../Sources/Lattice/Presentation/Feature/Feature.swift).

## Initialization

The initializer is `ViewModel(initialState:feature:)`. It stores the initial state as given and binds the new core to the main actor.

```swift
let viewModel = ViewModel(
    initialState: CounterState(),
    feature: Feature(interactor: CounterInteractor())
)
```

## Reading State

Views read the state through `State.ViewState`, the projection `@FeatureState` generates:

- `viewModel.member` (`subscript(dynamicMember: KeyPath<State.ViewState, V>)`) is the fine-grained read. It registers the root and then each member it walks through on the state's own registrars, so `viewModel.badge.count` re-renders only when `count` changes, `badge` is replaced with different content, or the whole state is replaced.
- `viewState: State.ViewState` is the whole projection. The value itself is coarse: it re-renders on a wholesale replacement or an enum case change. Members read off it stay fine-grained (the projection shares every registrar with the state), so `switch viewModel.viewState { case .loaded(let l): Text(l.title) }` re-renders on case changes and on `title` changes only.
- The raw `state` is internal. It reads `core.state`, which registers the coarse `\.state` key path on the core's `ObservationRegistrar`; that is the access `withObservationTracking` records for the root. `ScopedViewModel` and the bindings live in the same module and use it; views cannot.
- `ViewModel` keeps its `Observable` conformance for `@Bindable`; the registrar it would hold lives in the core.

A `@Domain` member is rejected at every read site with `'x' is unavailable: 'x' is @Domain state and is not visible to views`. See [FeatureState](./feature-state.md).

## Sending Actions

`sendViewEvent(_:) -> Task<Void, Never>?` is the only production event entry point. It is `@discardableResult` and synchronous: when it returns, the interactor has run, the new state is committed, the previous anonymous effects of the action's case are cancelled (at the root and at each child case a `When` routes it into), and every effect the action started has run its synchronous preamble. The returned task waits for exactly those effects; it is `nil` when the action started none, and cancelling it cancels them. See [Handling An Action](./effects-and-isolation.md#handling-an-action) and [The Task `send` Returns](./effects-and-isolation.md#the-task-send-returns).

```swift
.refreshable { await viewModel.sendViewEvent(.refresh)?.value }
```

A `.task` that starts a long-lived effect forwards its own cancellation to the returned task, because awaiting `Task.value` does not cancel it:

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

## Commit Rules

The core commits each action's result, and each `effects.modify`, by the same rules. The interactor (or the `modify` body) mutates a working copy of the state that shares every observation registrar with the stored state, so member notifications fire during the mutation, and an observer that re-reads the view model synchronously sees the previous committed value. The core then commits the result:

- If the new state has a different root `_$id` (a wholesale replacement) and `areStatesEqual` reports equal content, the current value is kept, so its registrar tree and every observer registered on it survive. Nothing changed for the view.
- Otherwise the new state is stored. If its root `_$id` changed, the core fires the coarse `\.state` key path. Every reader re-renders, because member reads register the root too.
- In-place member mutations keep the root `_$id`, so they reach views only through the member registrars.

[FeatureState](./feature-state.md#observation-guarantees) lists the guarantees the suite asserts, and [Fine-Grained Observation](./fine-grained-observation.md) explains why they hold.

## Teardown

`ViewModel` has an `isolated deinit` that invalidates the core, under an `#if swift(<6.4) @_optimize(none)` guard. Released on the main actor, the deinit runs inline, so every effect is cancelled before the release returns; released elsewhere, it runs as a main-actor job. After that, an effect's `effects.send` and `effects.modify` throw `CancellationError` without reporting an issue. See [Teardown](./effects-and-isolation.md#teardown).

## SwiftUI Bindings

`ViewModel` supports action-sending bindings through [`ViewModelBinding.swift`](../Sources/Lattice/Presentation/ViewModel/ViewModelBinding.swift).

There are two entry points:

- `@Bindable var viewModel: ViewModel<F>`
- `Binding<ViewModel<F>>`

Both expose dynamic-member access rooted at `F.State.ViewState`, and `.sending(...)` turns writes back into actions; the setter discards the task `sendViewEvent(_:)` returns. A `@Domain` member is rejected at the `$viewModel.member` site.

Examples:

- Property binding: `$viewModel.name.sending(\.nameChanged)`
- Nested member binding: `$viewModel.badge.label.sending(\.badge.labelChanged)`
- Enum-case member binding: `$viewModel.loaded.query.sending(\.queryChanged)`

Enum case bindings go through the state's `@CasePathable` `ViewState` mirror (`F.State.ViewState.AllCasePaths`), never the raw enum, so `@Domain` members of a `@FeatureState` payload stay hidden. They have two variants:

- `sending(_:)` traps if the current `viewState` is not in the expected case.
- `sending(_:default:)` returns a fallback value and suppresses writes until the case matches again.

These APIs require `CasePaths` support for case-path-based action construction.

## Scoping

`scope(state:action:)` projects the view model onto a child state for a child view, returning a stateless `ScopedViewModel`. Its `sendViewEvent(_:)` embeds the child action into the parent action and returns the parent's `Task<Void, Never>?`; its `binding(_:sending:)` setter discards it. Overloads cover a child, an optional child, a collection of identifiable children, an enum case (`scopeIfActive(state:action:)` and the trapping `scope(state:action:)`), a closure-mapped action, and a read-only child. See [Scoped View Composition](./scoped-view-composition.md) and [Enum-Case Scoping](./enum-case-scoping.md).

## What ViewModel Does Not Do

- It does not expose the raw state publicly.
- It does not own business logic; that stays in the interactor and its effects.
- It does not derive presentation values itself; computed members on the state do.
- It does not record commits for assertions; `TestModel` and `TestViewModel` do (see [Testing Infrastructure](./testing-infrastructure.md)).

## ActorModel

`ActorModel<F>` runs a feature on a serial executor of its own, off the main actor: for features that are not bound to a view, and for parallel tests.

```swift
@available(iOS 26, macOS 26, watchOS 26, *)
func syncInTheBackground(client: sending SyncClient) async -> Int {
    let model = await ActorModel(
        initialState: SyncState(),
        feature: Feature(interactor: SyncInteractor(client: client))
    )
    await model.send(.sync)?.value
    return await model.state.pendingCount  // reading from outside needs `SyncState: Sendable`
}
```

- It is a `public actor`, available from iOS 26, macOS 26 and watchOS 26 (`Task.immediate` and actor `isolated deinit`).
- Its core is bound to an internal `DefaultIsolation` actor, and `unownedExecutor` forwards to that actor's executor. The model's methods and its effects are serialized on that one executor, and `send` is processed synchronously on it, with the same preamble-before-return guarantee as `ViewModel`.
- `init(initialState:feature:)` is `async`, because a non-main actor's initializer is isolated only when it is async.
- `state` is the committed state. Reading it from another isolation (`await model.state`) needs `State: Sendable`, as for any actor-isolated property.
- `send(_:) -> Task<Void, Never>?` is `sendViewEvent(_:)`'s counterpart.
- It is not `Observable`, and it has no `ViewState` reads, bindings or scopes. It records nothing for assertions either: synchronize on the task `send` returns or on signals the effects give, or use `TestModel` in tests.
- The interactor must not be main-actor-isolated; such a feature cannot be sent to the model and uses `ViewModel`.
- Teardown is asynchronous: released off the model's executor, the `isolated deinit` runs later, as a job on that executor, and cancels every effect then.

## Related Specs

- [Effects And Isolation](./effects-and-isolation.md)
- [FeatureState](./feature-state.md)
- [Interactors](./interactors.md)
- [Testing Infrastructure](./testing-infrastructure.md)
- [Scoped View Composition](./scoped-view-composition.md)

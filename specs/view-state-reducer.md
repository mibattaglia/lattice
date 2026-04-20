# ViewStateReducer

`ViewStateReducer` is Lattice's synchronous projection layer from domain state into render state. It exists to keep presentation formatting and UI-facing derivation out of `ViewModel` and out of the interactor.

Key source files:

- [ViewStateReducer.swift](../Sources/Lattice/Presentation/ViewStateReducer/ViewStateReducer.swift)
- [BuildViewState.swift](../Sources/Lattice/Presentation/ViewStateReducer/BuildViewState.swift)
- [ViewStateReducerBuilder.swift](../Sources/Lattice/Presentation/ViewStateReducer/ViewStateReducerBuilder.swift)
- [DefaultValueProvider.swift](../Sources/Lattice/Observation/DefaultValueProvider.swift)
- [ViewStateReducerTests.swift](../Tests/LatticeTests/PresentationTests/ViewStateReducerTests.swift)

## Role

The reducer's job is narrow:

- Accept the current `DomainState`.
- Mutate an existing `ViewState` value in place.
- Produce render-ready output for SwiftUI.

It is not the place for:

- Side effects
- asynchronous work
- business-state mutation
- external dependency access

Those belong in the interactor.

## Protocol Shape

`ViewStateReducer` has three main requirements:

- `var body: Body`
- `func reduce(_ domainState: DomainState, into viewState: inout ViewState)`
- `func initialViewState(for domainState: DomainState) -> ViewState`

Most reducers implement only `body` and let the protocol extension forward both methods to that body.

## In-Place Mutation

Reducers mutate `ViewState` in place rather than returning a new value from scratch.

That is important for observation:

- Existing top-level identity can be preserved when appropriate.
- Nested `@ObservableState` values can keep stable identity across ordinary field updates.
- `ViewModel` can decide whether to publish the new state through the observation registrar based on the top-level `_$id`.

## BuildViewState

`BuildViewState` is the standard leaf reducer.

It packages two closures:

- `initial: (DomainState) -> ViewState`
- `reducerBlock: (DomainState, inout ViewState) -> Void`

Typical usage is:

```swift
@ViewStateReducer<DomainState, ViewState>
struct MyReducer {
    var body: some ViewStateReducerOf<Self> {
        BuildViewState { domainState, viewState in
            viewState.title = domainState.title
        }
    }
}
```

## Initial View State Rules

There are three valid ways to define initial view state:

1. Implement `initialViewState(for:)` on the reducer.
2. Use `BuildViewState(initial:reducerBlock:)`.
3. Make `ViewState` conform to `DefaultValueProvider` and rely on `.defaultValue`.

If you use `BuildViewState(reducerBlock:)` without one of those paths, asking for an initial view state traps.

## DefaultValueProvider

`DefaultValueProvider` is a small runtime protocol:

```swift
public protocol DefaultValueProvider {
    static var defaultValue: Self { get }
}
```

When `ViewState` conforms to it, `BuildViewState(reducerBlock:)` can synthesize its initial value with `.defaultValue`.

The `@ViewStateReducer` macro also uses this protocol when deciding whether it can synthesize `initialViewState(for:)`.

## Composition Limits

`ViewStateReducerBuilder` currently accepts a single reducer component. This is not a parallel to `InteractorBuilder`'s multi-child composition.

In practice, reducer composition today looks like one of these:

- Return `BuildViewState` directly.
- Forward to another reducer from `body`.

There is no runtime equivalent of `Merge`, `MergeMany`, or `When` for view-state reducers.

## How ViewModel Uses The Reducer

`ViewModel` stores a type-erased `AnyViewStateReducer<DomainState, ViewState>`.

It uses the reducer:

- During initialization, after building the initial `ViewState`.
- After sent actions whose domain state changed.
- After every emitted action, even if the feature's domain-state equality says the states are equal.

That last rule makes reducers the reliable place for presentation-only updates that depend on emitted-event timing or observable identity.

## Feature Integration

`Feature` bundles the reducer alongside the interactor and equality function.

When `DomainState == ViewState`, `Feature(interactor:)` constructs an identity reducer automatically with `BuildViewState` so the view model can still use the same runtime path.

## Practical Guidance

- Put strings, formatted dates, visibility flags, colors, and render-only enums in `ViewState`.
- Keep raw business models and mutation logic in `DomainState` and the interactor.
- Prefer `BuildViewState` for ordinary reducers.
- Use `initialViewState(for:)` when the initial render state must depend on domain data and cannot be expressed as a global default.

## Related Specs

- [ViewModel](./view-model.md)
- [Interactors](./interactors.md)
- [Macros](./macros.md)

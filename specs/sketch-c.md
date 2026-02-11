# Sketch C: Feature bundler with two initializers

## Goal
Provide a single bundling type for the architecture stack and make opting out of the
`ViewStateReducer` ergonomic (no typealias, no extra boilerplate) while retaining
compile-time safety.

## Core idea
Introduce a `Feature` struct that owns the full stack needed by `ViewModel`.
It has **two initializers**:
- `init(interactor:reducer:areStatesEqual:)` for the full pattern.
- `init(interactor:areStatesEqual:)` for opt-out when `DomainState == ViewState`.

No static factories. No DSL.

## Sketch

```swift
public struct Feature<Action, DomainState, ViewState>
where Action: Sendable, DomainState: Sendable, ViewState: ObservableState {
    public let interactor: AnyInteractor<DomainState, Action>
    public let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    public let makeInitialViewState: (DomainState) -> ViewState
    public let areStatesEqual: (DomainState, DomainState) -> Bool

    public init<I, R>(
        interactor: I,
        reducer: R,
        areStatesEqual: @escaping (DomainState, DomainState) -> Bool
    )
    where I: Interactor & Sendable,
          R: ViewStateReducer & Sendable,
          I.DomainState == DomainState, I.Action == Action,
          R.DomainState == DomainState, R.ViewState == ViewState
    {
        self.interactor = interactor.eraseToAnyInteractor()
        self.viewStateReducer = reducer.eraseToAnyReducer()
        self.makeInitialViewState = { R.initialViewState(for: $0) }
        self.areStatesEqual = areStatesEqual
    }

    public init<I>(
        interactor: I,
        areStatesEqual: @escaping (DomainState, DomainState) -> Bool
    )
    where I: Interactor & Sendable,
          I.DomainState == DomainState, I.Action == Action,
          DomainState == ViewState
    {
        self.interactor = interactor.eraseToAnyInteractor()
        self.viewStateReducer = BuildViewState { domain, view in view = domain }.eraseToAnyReducer()
        self.makeInitialViewState = { $0 }
        self.areStatesEqual = areStatesEqual
    }
}
```

### Equatable convenience

When `DomainState: Equatable`, provide overloads that default `areStatesEqual` to `==`:

```swift
public extension Feature where DomainState: Equatable {
    init<I, R>(
        interactor: I,
        reducer: R
    )
    where I: Interactor & Sendable,
          R: ViewStateReducer & Sendable,
          I.DomainState == DomainState, I.Action == Action,
          R.DomainState == DomainState, R.ViewState == ViewState
    {
        self.init(interactor: interactor, reducer: reducer, areStatesEqual: { $0 == $1 })
    }

    init<I>(
        interactor: I
    )
    where I: Interactor & Sendable,
          I.DomainState == DomainState, I.Action == Action,
          DomainState == ViewState
    {
        self.init(interactor: interactor, areStatesEqual: { $0 == $1 })
    }
}
```

## ViewModel integration

```swift
public extension ViewModel {
    convenience init(
        initialDomainState: DomainState,
        feature: Feature<Action, DomainState, ViewState>
    ) {
        self.init(
            initialDomainState: initialDomainState,
            initialViewState: feature.makeInitialViewState(initialDomainState),
            interactor: feature.interactor,
            viewStateReducer: feature.viewStateReducer,
            areStatesEqual: feature.areStatesEqual
        )
    }
}
```

## Usage

Full pattern:

```swift
let feature = Feature(
    interactor: CounterInteractor(),
    reducer: CounterViewStateReducer(),
    areStatesEqual: { $0 == $1 }
)

let viewModel = ViewModel(
    initialDomainState: CounterDomainState(count: 0),
    feature: feature
)
```

Opt-out pattern:

```swift
let feature = Feature(
    interactor: CounterInteractor(),
    areStatesEqual: { $0 == $1 }
)

let viewModel = ViewModel(
    initialDomainState: CounterState(count: 0),
    feature: feature
)
```

## Notes
- This relies on Sketch A's `ViewStateReducer.initialViewState(for:)` hook.
- The opt-out initializer is only available when `DomainState == ViewState`,
  so compile-time safety is preserved.
- Target state: docs/tests/examples prefer `Feature` usage; remove `BFFViewModel`
  typealias once the Feature-based API is established.

## Follow-up updates

### Tests
- Update view model tests to construct `Feature` and pass to `ViewModel` rather than
  direct initializers.
- Replace `BFFViewModel` tests with `Feature` opt-out initializer coverage.
- Add a small `Feature` unit test to assert reducer + initial view state wiring.

### Docs & examples
- Update README and `Sources/LatticeCLI/Resources/agent-docs.md` to show
  `Feature`-based initialization for both patterns.
- Update ExampleProject initializers to create a `Feature` and pass it into `ViewModel`.
- Remove all references to `BFFViewModel` once it is deleted.

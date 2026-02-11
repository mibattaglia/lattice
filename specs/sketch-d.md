# Sketch D: Macro-driven view state wiring (no Feature type)

## Goal
Make the "full" ViewModel initialization as ergonomic as the opt-out path by
attaching a view state reducer directly to the interactor via a macro.

Call site becomes:

```swift
let viewModel = ViewModel(
    initialDomainState: CounterDomainState(count: 0),
    interactor: CounterInteractor()
)
```

## Macro

```swift
@Interactor<CounterDomainState, CounterAction>
@FeatureViewState<CounterViewStateReducer>
struct CounterInteractor: Sendable { ... }
```

The macro expands to:

```swift
extension CounterInteractor: FeatureViewStateProvider {
    typealias ViewStateReducerType = CounterViewStateReducer
    typealias ViewState = CounterViewStateReducer.ViewState

    static func makeViewStateReducer() -> CounterViewStateReducer {
        CounterViewStateReducer()
    }
}
```

## Protocol

```swift
public protocol FeatureViewStateProvider {
    associatedtype ViewStateReducerType: ViewStateReducer & Sendable
    associatedtype ViewState = ViewStateReducerType.ViewState

    static func makeViewStateReducer() -> ViewStateReducerType
}
```

## ViewModel init

```swift
public extension ViewModel {
    convenience init<I>(
        initialDomainState: DomainState,
        interactor: I,
        areStatesEqual: @escaping (DomainState, DomainState) -> Bool
    )
    where I: Interactor & Sendable,
          I.DomainState == DomainState, I.Action == Action,
          I: FeatureViewStateProvider,
          I.ViewStateReducerType.DomainState == DomainState,
          I.ViewStateReducerType.ViewState == ViewState
    {
        let reducer = I.makeViewStateReducer()
        self.init(
            initialDomainState: initialDomainState,
            initialViewState: I.ViewStateReducerType.initialViewState(for: initialDomainState),
            interactor: interactor.eraseToAnyInteractor(),
            viewStateReducer: reducer.eraseToAnyReducer(),
            areStatesEqual: areStatesEqual
        )
    }
}
```

## Notes
- This relies on Sketch A's `ViewStateReducer.initialViewState(for:)` hook.
- If the macro isn’t applied, the initializer above is unavailable; the opt-out
  initializer still applies when `DomainState == ViewState`.
- `makeViewStateReducer()` allows reducers to be constructed with custom logic
  if needed (macro can emit `.init()` by default).

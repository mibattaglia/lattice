# Sketch A: Reducer-provided initial view state + erased convenience init

## Goal
Reduce view model initialization boilerplate while keeping the current architecture.
Specifically:
- No `.eraseToAny*` at call sites.
- No `initialViewState:` parameter at call sites.
- Keep `ViewModel` as the coordinator and `ViewStateReducer` as a separate type.

## Proposed Changes

### 1) Add a static initial view state hook on `ViewStateReducer`
The reducer provides the initial view state given the initial domain state.

```swift
public protocol ViewStateReducer<DomainState, ViewState> {
    associatedtype DomainState
    associatedtype ViewState
    associatedtype Body: ViewStateReducer

    @ViewStateReducerBuilder<DomainState, ViewState>
    var body: Body { get }

    func reduce(_ domainState: DomainState, into viewState: inout ViewState)

    // New: default initial view state hook.
    static func initialViewState(for domainState: DomainState) -> ViewState
}
```

Provide a default implementation that is explicit about the requirement:

```swift
public extension ViewStateReducer {
    static func initialViewState(for _: DomainState) -> ViewState {
        fatalError("\(Self.self) must implement initialViewState(for:)")
    }
}
```

This keeps the API surface minimal (no new protocol), but allows
reducers to own their default view state construction.

### 2) Add convenience initializers that erase internally
Allow passing `some Interactor` / `some ViewStateReducer` directly.

```swift
public extension ViewModel {
    convenience init<I, R>(
        initialDomainState: DomainState,
        interactor: I,
        viewStateReducer: R,
        areStatesEqual: @escaping (_ lhs: DomainState, _ rhs: DomainState) -> Bool
    )
    where I: Interactor & Sendable,
          R: ViewStateReducer & Sendable,
          I.DomainState == DomainState, I.Action == Action,
          R.DomainState == DomainState, R.ViewState == ViewState
    {
        let initialViewState = R.initialViewState(for: initialDomainState)
        self.init(
            initialDomainState: initialDomainState,
            initialViewState: initialViewState,
            interactor: interactor.eraseToAnyInteractor(),
            viewStateReducer: viewStateReducer.eraseToAnyReducer(),
            areStatesEqual: areStatesEqual
        )
    }
}
```

Provide a `DomainState: Equatable` overload mirroring existing behavior.

### 3) Example usage

```swift
@ViewStateReducer<CounterDomainState, CounterViewState>
struct CounterViewStateReducer: Sendable {
    static func initialViewState(for domainState: CounterDomainState) -> CounterViewState {
        CounterViewState(count: domainState.count, displayText: "")
    }

    var body: some ViewStateReducerOf<Self> {
        BuildViewState { domainState, viewState in
            viewState.count = domainState.count
            viewState.displayText = "Count: \(domainState.count)"
        }
    }
}

let viewModel = ViewModel(
    initialDomainState: CounterDomainState(count: 0),
    interactor: CounterInteractor(),
    viewStateReducer: CounterViewStateReducer()
)
```

## Notes
- This can ship independently of any Feature-based design.
- If we later introduce a `Feature` wrapper, it can re-use
  `ViewStateReducer.initialViewState(for:)` for its default construction path.

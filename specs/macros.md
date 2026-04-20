# Macros

Lattice uses macros to turn small declarations into the boilerplate required by the runtime protocols. The public entry points live in [`Sources/Lattice/Macros.swift`](../Sources/Lattice/Macros.swift), and the compiler plugin lives in [`Sources/LatticeMacros`](../Sources/LatticeMacros).

Key source files:

- [Macros.swift](../Sources/Lattice/Macros.swift)
- [Plugin.swift](../Sources/LatticeMacros/Plugins/Plugin.swift)
- [InteractorMacro.swift](../Sources/LatticeMacros/Plugins/InteractorMacro.swift)
- [ViewStateReducerMacro.swift](../Sources/LatticeMacros/Plugins/ViewStateReducerMacro.swift)
- [ObservableStateMacro.swift](../Sources/LatticeMacros/Plugins/Derived/ObservableStateMacro.swift)

## Public Macros

The plugin registers five macros:

- `@Interactor<DomainState, Action>`
- `@ViewStateReducer<DomainState, ViewState>`
- `@ObservableState`
- `@ObservationStateTracked`
- `@ObservationStateIgnored`

Only the first three are the ordinary user-facing API surface. The tracked and ignored macros are helper pieces used by `@ObservableState`.

## `@Interactor`

`@Interactor<DomainState, Action>` synthesizes the pieces needed to conform a type to the runtime `Interactor` protocol.

It adds:

- `typealias DomainState`
- `typealias Action`
- `@Lattice.InteractorBuilder<...>` on a getter-only `body` property
- `extension Type: Lattice.Interactor {}` if that conformance is not already declared

The runtime target is [`Interactor.swift`](../Sources/Lattice/Domain/Interactor.swift).

### Diagnostics

`@Interactor` requires exactly two generic arguments.

Current diagnostics include:

- hard error when generics are missing
- hard error when more than two generics are supplied
- warning when explicit `typealias DomainState` or `typealias Action` duplicates what the macro would synthesize

See [InteractorMacroTests.swift](../Tests/LatticeMacrosTests/InteractorMacroTests.swift).

## `@ViewStateReducer`

`@ViewStateReducer<DomainState, ViewState>` is the reducer-side parallel to `@Interactor`.

It adds:

- `typealias DomainState`
- `typealias ViewState`
- `@Lattice.ViewStateReducerBuilder<...>` on a getter-only `body`
- `extension Type: Lattice.ViewStateReducer {}`
- sometimes `initialViewState(for:)`

The runtime target is [`ViewStateReducer.swift`](../Sources/Lattice/Presentation/ViewStateReducer/ViewStateReducer.swift).

### Initial View State Synthesis

The macro may synthesize:

```swift
func initialViewState(for _: DomainState) -> ViewState {
    .defaultValue
}
```

That happens only when:

- there is no existing `initialViewState(for:)`
- the macro sees `BuildViewState` or `buildViewState` in the body source
- the view-state type appears compatible with `DefaultValueProvider`

This logic is heuristic, not semantic. It is based on source inspection and string matching, not on full type checking.

### Diagnostics And Caveats

Like `@Interactor`, it requires exactly two generic arguments and warns about redundant typealiases.

Additional caveats from the current implementation:

- the generic parsing is narrower than `@Interactor` and currently expects identifier-style type syntax
- member expansion reads generics from the first declaration attribute, so attribute ordering matters more than it should
- synthesis of `initialViewState(for:)` depends on heuristic detection of `BuildViewState`

See [ViewStateReducerMacroTests.swift](../Tests/LatticeMacrosTests/ViewStateReducerMacroTests.swift).

## `@ObservableState`

`@ObservableState` adds observation behavior to value types used as view state.

On structs it synthesizes:

- `_$observationRegistrar`
- `_$id`
- `_$willModify()`
- observer-notification helpers
- tracked accessors around stored mutable properties

On enums it synthesizes `_$id` and `_$willModify()` with special handling for associated values.

The runtime target is [`ObservableState.swift`](../Sources/Lattice/Observation/ObservableState.swift).

### Property Rules

`@ObservableState` tracks mutable stored instance `var` properties.

It does not auto-track:

- `let` properties
- computed properties
- `static` or `class` properties
- properties explicitly marked ignored

### Enum Behavior

Enum handling is specialized:

- single associated-value cases propagate nested `_$id` and nested `_$willModify()`
- zero-value and multi-value cases use a tagged fresh `ObservableStateID`

This preserves useful identity behavior for common enum-based view-state modeling while avoiding unsupported assumptions for more complex cases.

### Diagnostics

The macro rejects classes and actors.

It also diagnoses older observation attribute names and suggests the current Lattice spellings.

See [ObservableStateMacroTests.swift](../Tests/LatticeMacrosTests/ObservableStateMacroTests.swift).

## Helper Macros

`@ObservationStateTracked` is the property-level helper behind `@ObservableState`.

It synthesizes:

- storage initialization
- `get`
- `set`
- `_modify`
- a private underscored peer storage property marked ignored

`@ObservationStateIgnored` is a marker macro used to opt a property out of observation.

## Runtime Relationship

The macros do not replace the runtime protocols. They automate the conformance boilerplate around them.

- `@Interactor` targets `Interactor`
- `@ViewStateReducer` targets `ViewStateReducer`
- `@ObservableState` targets `ObservableState` and `Observation.Observable`

The generated code still relies on the library's runtime types such as `InteractorBuilder`, `ViewStateReducerBuilder`, `ObservationStateRegistrar`, and `DefaultValueProvider`.

## Practical Guidance

- Prefer the macros for ordinary feature declarations.
- Still understand the runtime protocols, because the macros only synthesize boilerplate around those contracts.
- Be cautious with unusual generic syntax and extra declaration attributes around `@ViewStateReducer` until its implementation is widened.

## Related Specs

- [ViewStateReducer](./view-state-reducer.md)
- [Interactors](./interactors.md)

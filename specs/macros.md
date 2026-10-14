# Macros

Lattice uses macros to turn small declarations into the boilerplate required by the runtime protocols. The public entry points live in [`Sources/Lattice/Macros.swift`](../Sources/Lattice/Macros.swift), and the compiler plugin lives in [`Sources/LatticeMacros`](../Sources/LatticeMacros).

Key source files:

- [Macros.swift](../Sources/Lattice/Macros.swift)
- [Plugin.swift](../Sources/LatticeMacros/Plugins/Plugin.swift)
- [InteractorMacro.swift](../Sources/LatticeMacros/Plugins/InteractorMacro.swift)
- [FeatureStateMacro.swift](../Sources/LatticeMacros/Plugins/FeatureStateMacro.swift)
- [FeatureStateSupportMacros.swift](../Sources/LatticeMacros/Plugins/FeatureStateSupportMacros.swift)

## Public Macros

The plugin registers eight macro implementations behind these declarations:

- `@Interactor<State, Action>`
- `@FeatureState`
- `@Domain`
- `@_IdentifiableIfPossible(_:)` and `@_EquatableIfPossible(_:)`, each declared twice: a constrained overload (`IdentifiableIfPossibleMacro`, `EquatableIfPossibleMacro`) and an unconstrained one (`NoOpExtensionMacro`)
- `@ObservationStateTracked`
- `@ObservationStateIgnored`

`@Interactor`, `@FeatureState` and `@Domain` are the ordinary user-facing API surface. The underscored conformance macros are applied by `@FeatureState` to the `ViewState` it generates, and the tracked and ignored macros are applied by its member-attribute role.

## `@Interactor`

`@Interactor<State, Action>` synthesizes the pieces needed to conform a type to the runtime `Interactor` protocol.

It adds:

- `typealias State`
- `typealias Action`
- `@Lattice.InteractorBuilder<...>` on a getter-only `body` property
- `extension Type: Lattice.Interactor {}` if that conformance is not already declared

The runtime target is [`Interactor.swift`](../Sources/Lattice/Domain/Interactor.swift).

### Diagnostics

`@Interactor` requires exactly two generic arguments.

Current diagnostics include:

- hard error when generics are missing
- hard error when more than two generics are supplied
- warning when explicit `typealias State` or `typealias Action` duplicates what the macro would synthesize

A first argument spelled with the bare name `State` (a sibling type, or a top-level type literally named `State`) generates `typealias State = State`, which fails with "type alias 'State' references itself"; qualify it (`@Interactor<Foo.State, Foo.Action>`). `Action` behaves the same way.

See [InteractorMacroTests.swift](../Tests/LatticeMacrosTests/InteractorMacroTests.swift).

## `@FeatureState`

`@FeatureState` makes a struct or enum a feature's state: it adds per-member observation and generates the `ViewState` projection that views read through. [FeatureState](./feature-state.md) describes the projection, its visibility rules and its limitations; this section covers the macro's roles.

```swift
@attached(
    member,
    names: named(_$id), named(_$observationRegistrar), named(_$willModify), named(shouldNotifyObservers),
    named(ViewState), named(_$ViewStateTypes), named(_$ViewStateWitness)
)
@attached(memberAttribute)
@attached(extension, conformances: FeatureState, Observable)
public macro FeatureState() = #externalMacro(module: "LatticeMacros", type: "FeatureStateMacro")
```

- The member role synthesizes the observation members and the projection declarations: the `_$ViewStateTypes` protocol, the `_$ViewStateWitness` struct, and the nested `ViewState` (a struct for struct states, a mirror enum for enum states).
- The member-attribute role adds `@ObservationStateTracked` to each stored mutable instance property not already marked `@ObservationStateIgnored`. A property-wrapped member needs `@ObservationStateIgnored`, because a property wrapper cannot be applied to the computed property that the tracking accessors make.
- The extension role adds `extension Type: Lattice.FeatureState, Observation.Observable {}`.

`names: arbitrary` is not needed: projection members live inside the generated `ViewState` type.

The runtime targets are [`FeatureState.swift`](../Sources/Lattice/Observation/FeatureState.swift), [`ViewStateProjection.swift`](../Sources/Lattice/Observation/ViewStateProjection.swift), [`ViewStateCollection.swift`](../Sources/Lattice/Observation/ViewStateCollection.swift) and [`Projection.swift`](../Sources/Lattice/Observation/Projection.swift).

### Observation Members

On structs it synthesizes:

- `_$observationRegistrar`
- `_$id`
- `_$willModify()`
- observer-notification helpers (`shouldNotifyObservers`)
- tracked accessors around stored mutable properties, `@Domain` ones included

On enums it synthesizes `_$id` and `_$willModify()` with special handling for associated values.

### Property Rules

`@FeatureState` tracks mutable stored instance `var` properties.

It does not auto-track:

- `let` properties
- computed properties
- `static` or `class` properties
- properties explicitly marked ignored

A multi-binding `var` (`var a = 0, b = 0`) is rejected by the tracked-accessor macro, which supports one variable per declaration.

Which members appear in `ViewState` is a separate rule (visible members, `@Domain`), described in [FeatureState](./feature-state.md#visibility-rules).

### Enum Behavior

Enum identity is specialized:

- a single associated-value case propagates the payload's `_$id` (through `ObservableStateID._$id(for:)`) and its `_$willModify()`, tagged with the case index
- payload-less and multi-value cases return `ObservableStateID._$inert._$tag(n)`, an identity that is stable across accesses and distinct across cases

A single non-`FeatureState` payload has no identity of its own, so `_$id(for:)` mints a fresh one on every access and every commit while that case is active looks like a replacement (the coarse path; the `areStatesEqual` gate swallows equal-content commits). Multi-value cases therefore never change their identity on a content change; this is a known gap, listed in [FeatureState](./feature-state.md#limitations).

### Projection Generation

- Each visible member becomes a forwarding getter typed through the witness (`_$ViewStateWitness.member`) and implemented as `Lattice._$project(_state.member)`.
- Each `@Domain` member becomes an `@available(*, unavailable, message:)` stub.
- Enum mirrors copy the cases with their labels, type the payloads through the witness, build `init(_:)` from `_$project` and `_state` from `_$unproject(_:to:)`, and carry `@CasePathable` and `indirect` over from the state.
- `ViewState` gets `@_IdentifiableIfPossible(Type.self)` and `@_EquatableIfPossible(Type.self)`. Their arguments are type-checked, so the compiler selects the constrained overload (which adds `Identifiable`, or `Equatable` with `==` comparing `_state`) exactly when the state has the conformance. `Sendable` is emitted syntactically, from the state's inheritance clause.
- The generated declarations take the state's access level; `_state` is always `@_spi(Lattice) public`.

### Diagnostics

The macro rejects classes and actors.

It rejects generic structs and enums, because the generated projection needs a nested protocol, which Swift does not allow inside generic types (SE-0404). Both roles report it and nothing is generated.

It reserves the names `ViewState`, `_$ViewStateTypes` and `_$ViewStateWitness` (members and nested types) and `_state` (properties and cases). After a reserved-name error no `ViewState` is generated and the extension adds only `Observation.Observable`.

It diagnoses `@Domain` on anything but an instance property, and `@Domain` on `id` when the inheritance clause lists `Identifiable` (the stub cannot satisfy `Identifiable`; it is left out after the error).

It also diagnoses older observation attribute names and suggests the current Lattice spellings.

The exact messages are listed in [FeatureState](./feature-state.md#diagnostics).

See [FeatureStateMacroTests.swift](../Tests/LatticeMacrosTests/FeatureStateMacroTests.swift). The tests pass `MacroSpec(type:conformances:)` for `@FeatureState`, because the extension role only expands when the expansion is told which conformances are missing.

### File Layout (Swift 6.4)

A known Swift 6.4 compiler bug: a source file that holds a `@FeatureState` enum together with other macro-annotated declarations (other `@FeatureState` types, `@CasePathable` enums, `@Observable` classes, `@Interactor` types, …) can crash the compiler with a segfault in `TypeCheckPrimaryFileRequest`, apparently from type-checking the extensions that the attached macros on the generated `ViewState` declarations synthesize. Declare each `@FeatureState` enum, `@CasePathable` or not, in its own file with no other macro-annotated declaration. Files whose `@FeatureState` types are all structs are not affected. This is a temporary layout rule that works around the compiler bug, not a design choice. The test fixtures and examples follow it: each `@FeatureState` enum sits alone in its file, with a comment pointing at §10 of the [plan](./plans/unified-feature-state.md#10-limitations).

## `@Domain`

`@Domain` is a no-op peer macro. `@FeatureState` reads it syntactically and leaves the property out of `ViewState`, emitting an unavailable stub instead. It applies to any instance property, stored or computed, of a struct or enum state, and the property keeps its `@ObservationStateTracked` accessors.

## Helper Macros

`@ObservationStateTracked` is the property-level helper behind `@FeatureState`.

It synthesizes:

- storage initialization
- `get`
- `set`
- `_modify`
- a private underscored peer storage property marked ignored

`@ObservationStateIgnored` is a marker macro used to opt a property out of observation.

`@_IdentifiableIfPossible(_:)` and `@_EquatableIfPossible(_:)` are the conformance helpers described under [Projection Generation](#projection-generation). Their unconstrained overloads expand to nothing.

## Runtime Relationship

The macros do not replace the runtime protocols. They automate the conformance boilerplate around them.

- `@Interactor` targets `Interactor`
- `@FeatureState` targets `FeatureState` and `Observation.Observable`, and its generated `ViewState` targets `ViewStateProjection`

The generated code still relies on the library's runtime types such as `InteractorBuilder`, `ObservationStateRegistrar`, `ObservableStateID`, `ViewStateCollection`, and the `_$project`, `_$unproject` and `_$placeholder` functions.

## Practical Guidance

- Prefer the macros for ordinary feature declarations.
- Still understand the runtime protocols, because the macros only synthesize boilerplate around those contracts.
- Never conform to `FeatureState` or `ViewStateProjection` by hand; apply `@FeatureState`.
- Keep each `@FeatureState` enum in its own file until the Swift 6.4 crash is fixed.

## Related Specs

- [FeatureState](./feature-state.md)
- [Interactors](./interactors.md)

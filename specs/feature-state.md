# FeatureState

A feature has one `State`. `@FeatureState` makes that struct or enum observation-tracked per member and generates a nested `ViewState` projection that views read through. `@Domain` hides a member from the projection at compile time while keeping it tracked, so a visible computed member that depends on a hidden stored member still re-renders fine-grained. The feature's interactor is the only code that mutates the state.

This replaces the earlier split into a domain state, a separate view state, and a reducer between them. The design record, including the migration table, is the [unified feature state plan](./plans/unified-feature-state.md).

Key source files:

- [FeatureState.swift](../Sources/Lattice/Observation/FeatureState.swift): `FeatureState`, `ObservableStateID`, `_$isIdentityEqual`
- [ViewStateProjection.swift](../Sources/Lattice/Observation/ViewStateProjection.swift)
- [ViewStateCollection.swift](../Sources/Lattice/Observation/ViewStateCollection.swift)
- [Projection.swift](../Sources/Lattice/Observation/Projection.swift): `_$project`, `_$unproject`, `_$placeholder`
- [ObservationStateRegistrar.swift](../Sources/Lattice/Observation/ObservationStateRegistrar.swift)
- [Macros.swift](../Sources/Lattice/Macros.swift)
- [FeatureStateMacro.swift](../Sources/LatticeMacros/Plugins/FeatureStateMacro.swift)
- [FeatureStateSupportMacros.swift](../Sources/LatticeMacros/Plugins/FeatureStateSupportMacros.swift)
- [FeatureStateMacroTests.swift](../Tests/LatticeMacrosTests/FeatureStateMacroTests.swift)
- [ProjectionTests.swift](../Tests/LatticeTests/ObservationTests/ProjectionTests.swift), [ViewStateProjectionTests.swift](../Tests/LatticeTests/ObservationTests/ViewStateProjectionTests.swift), [ViewStateCollectionTests.swift](../Tests/LatticeTests/ObservationTests/ViewStateCollectionTests.swift)
- [Tests/NegativeCompileChecks](../Tests/NegativeCompileChecks) and [negative-compile-checks.sh](../scripts/negative-compile-checks.sh)

## Role

The state holds everything a feature knows: business data, workflow state, and the values views render.

- The interactor mutates it (`Interactor.State`); nothing else does.
- Views read it only through `State.ViewState`, which omits `@Domain` members.
- Every member is observation-tracked, `@Domain` ones included, and a view re-renders only when a member it read changes.

Presentation derivation lives on the state itself:

- Display values derived from domain data are computed members, recomputed on each read.
- A derived value that is expensive to compute can be a visible stored member that the interactor keeps in sync.
- The initial state is the argument of `ViewModel(initialState:feature:)`.

## Declaring A State

```swift
@FeatureState
public struct CounterState: Equatable, Sendable {
    public var title = "Counter"
    @Domain public var lastUpdatedAt: Date?
    @Domain var nonce = 0
    public var badge = BadgeState(id: 0)
    public var detail: BadgeState?
    public var rows: IdentifiedArrayOf<BadgeState> = []
    public var tags: [String] = []
    public var lastUpdatedText: String { lastUpdatedAt.map(Self.format) ?? "Never" }
    private var scratch = 0
}
```

`BadgeState` is itself a `@FeatureState` struct. The members of `CounterState.ViewState` are:

| State member | `CounterState.ViewState` member | Kind |
|---|---|---|
| `title` | `title: String` | leaf |
| `badge` | `badge: BadgeState.ViewState` | child state |
| `detail` | `detail: BadgeState.ViewState?` | optional child state |
| `rows` | `rows: ViewStateCollection<IdentifiedArrayOf<BadgeState>>` | collection of child states |
| `tags` | `tags: [String]` | leaf (the elements are not states) |
| `lastUpdatedText` | `lastUpdatedText: String` | computed leaf |
| `lastUpdatedAt`, `nonce` | unavailable stubs | `@Domain` |
| `scratch` | none | `private` |

Nesting needs no annotation. The generated code passes each member through `Lattice._$project(_:)`, and overload resolution picks the leaf overload or the child, optional-child or collection overload. The macro never inspects types.

A file that declares a `@FeatureState` type needs `Observation` in scope: the generated conformance names `Observation.Observable`. Importing `Foundation` or `SwiftUI` provides it.

### Visibility Rules

- A visible member is an instance `var` or `let`, stored or computed, that is not `private`/`fileprivate`, not `static`/`class`, and not `@Domain`. `private(set)` and `internal(set)` members are visible.
- `@Domain` hides a member. It applies to any instance property, stored or computed, of a struct or enum state, and the property keeps its observation tracking. `ViewState` gets an unavailable stub, so a read reports `'x' is unavailable: 'x' is @Domain state and is not visible to views`. The stub has the property's explicit type, or a witness-inferred type when the type is inferred.
- Property-wrapped members are forwarded as their wrapped value, as a leaf.
- `#if` member blocks are mirrored in all the generated declarations, so conditional members stay conditional.
- The generated declarations take the state's access level (`public`, `package`, or internal; `fileprivate` for a file-private state). `_state` is always `@_spi(Lattice) public`.
- `ViewState` is `Sendable` when `Sendable` (or `@unchecked Sendable`) appears in the state's inheritance clause.
- `ViewState` is `Identifiable` and `Equatable` when the state is, including conformances declared in other files. `==` compares the projected states.
- Methods, and members declared in extensions of the state, are not part of `ViewState`.

## The Generated `ViewState`

For the struct above, `@FeatureState` generates the observation members (`_$observationRegistrar`, `_$id`, `_$willModify()`, `shouldNotifyObservers`, and `@ObservationStateTracked` accessors on every stored `var`, `@Domain` ones included), the extension `extension CounterState: Lattice.FeatureState, Observation.Observable {}`, and these projection declarations (abridged from the compiler's expansion):

```swift
public protocol _$ViewStateTypes {
    associatedtype title
    var _$title: title { get }
    associatedtype nonce
    var _$nonce: nonce { get }
    associatedtype badge
    var _$badge: badge { get }
    // … detail, rows, tags, lastUpdatedText
}

public struct _$ViewStateWitness: _$ViewStateTypes {
    public let _$title = Lattice._$project(Lattice._$placeholder(CounterState.self).title)
    public let _$nonce = Lattice._$placeholder(CounterState.self).nonce
    public let _$badge = Lattice._$project(Lattice._$placeholder(CounterState.self).badge)
    // … detail, rows, tags, lastUpdatedText
}

@Lattice._IdentifiableIfPossible(CounterState.self)
@Lattice._EquatableIfPossible(CounterState.self)
public struct ViewState: Lattice.ViewStateProjection, Sendable {
    @_spi(Lattice) public let _state: CounterState
    public init(_ state: CounterState) {
        self._state = state
    }
    public var title: _$ViewStateWitness.title {
        Lattice._$project(_state.title)
    }
    public var badge: _$ViewStateWitness.badge {
        Lattice._$project(_state.badge)
    }
    // … detail, rows, tags, lastUpdatedText
    @available(*, unavailable, message: "'lastUpdatedAt' is @Domain state and is not visible to views")
    public var lastUpdatedAt: Date? {
        fatalError()
    }
    @available(*, unavailable, message: "'nonce' is @Domain state and is not visible to views")
    public var nonce: _$ViewStateWitness.nonce {
        fatalError()
    }
}
```

- `_$ViewStateTypes` and `_$ViewStateWitness` turn the type that `_$project` resolves to into a nameable associated type, through associated-type inference. The witness is a struct with instance `let`s and is never instantiated; `_$placeholder` is a type witness that traps if it is ever called.
- An inferred-type `@Domain` member (`nonce`) gets a witness entry without `_$project`, which types its stub.
- A projection is a struct copy of the state (~30 ns) that shares every observation registrar with it, so each forwarded getter registers on the live state's registrars: reading `viewModel.badge.count` tracks `badge` and `count` exactly as reading the state would.
- The overloaded `_IdentifiableIfPossible` and `_EquatableIfPossible` extension macros take the state type as a type-checked argument, so the compiler picks the overload that matches the state's actual conformances.

## Enum States

An enum state gets a mirror enum named `ViewState`. For

```swift
@CasePathable
@FeatureState
enum Phase: Equatable {
    case loading
    case loaded(LoadedState)
    case failed(message: String, retryCount: Int)
    var isBusy: Bool { if case .loading = self { true } else { false } }
    @Domain var retryBudget: Int { 3 }
}
```

the generated mirror is (abridged):

```swift
@Lattice._IdentifiableIfPossible(Phase.self)
@Lattice._EquatableIfPossible(Phase.self)
@CasePathable
enum ViewState: Lattice.ViewStateProjection {
    case loading
    case loaded(_$ViewStateWitness.loaded_0)  // LoadedState.ViewState
    case failed(message: _$ViewStateWitness.failed_0, retryCount: _$ViewStateWitness.failed_1)
    init(_ state: Phase) { … }  // each payload through Lattice._$project
    @_spi(Lattice) public var _state: Phase { … }  // each payload through Lattice._$unproject(_:to:)
    var isBusy: _$ViewStateWitness.isBusy {
        Lattice._$project(_state.isBusy)
    }
    @available(*, unavailable, message: "'retryBudget' is @Domain state and is not visible to views")
    var retryBudget: Int {
        fatalError()
    }
}
```

- Cases are mirrored with their labels. Payload types are copied from the `case` syntax and wrapped as `(T).self`, so `T?` and `[T]` parse. Payload-less cases need no witness.
- `init(_:)` projects each payload with `_$project`. `_state` rebuilds the state with `_$unproject(_:to:)`, whose explicit target type makes exactly one overload viable even when a payload is itself some `X.ViewState`.
- `@CasePathable` is added to the mirror when the state enum carries it, and `indirect` is propagated. `@dynamicMemberLookup` is not propagated: read payloads with `switch` or `viewState[case: \.loaded]`.
- Cases inside `#if` are mirrored under the same clauses. Computed members are forwarded like struct members, and `@Domain` ones are stubbed.
- Enum scoping and enum case bindings go through the `@CasePathable` mirror, never the raw enum.

### Payload Kinds

The leaf-or-child classification is automatic for payloads too, but the two kinds behave differently:

| | `@FeatureState` payload | Plain payload (`String`, `Error`, DTO, un-annotated struct) |
|---|---|---|
| Mirror case | `case loaded(LoadedState.ViewState)` | `case loaded(LoadedState)`, exposed raw |
| `@Domain` inside the payload | hidden | not possible |
| Observation while the case is active | fine-grained: a payload member edit fires only that member's observers; the root `_$id` is unchanged | coarse: every content change in the case fires the root and re-renders the views that switch over the state; equal-content commits are swallowed by the `areStatesEqual` gate |
| `scopeIfActive(state: \.loaded, action:)` | available | not available |
| `$viewModel.loaded.query.sending(...)` | through `LoadedState.ViewState` | through the raw payload |
| `Interactors.When(state: \.loaded, ...)` | available | available |

The coarse path is correct by necessity: a plain payload has no registrars, so a fresh root id is the only change signal. The convention is that a payload struct the feature owns is `@FeatureState`, while primitive and foreign payloads stay plain. The macro cannot tell a forgotten `@FeatureState` from a deliberate leaf without false positives, so this is a convention, not a diagnostic.

The coarse row holds for single-payload cases. A case with several payload values, such as `failed(message:retryCount:)`, currently keeps the stable identity of a payload-less case, so a content change inside it does not fire the root; see [Limitations](#limitations).

## Collections

`ViewStateCollection<Base>` is a lazily projecting `RandomAccessCollection` over a collection of child states. Its elements are `Base.Element.ViewState`, and its indices are the base collection's indices.

- `rows[id: id]` looks an element up when the base is an `IdentifiedArray`.
- `ids` returns the base collection's indices (`Base.Indices`), not element ids.
- `ForEach(viewModel.rows) { row in … }` works when the element state is `Identifiable`, because its `ViewState` is.
- For a child view per element, scope instead: `viewModel.scope(state: \.rows, action: \.row)`; see [Scoped View Composition](./scoped-view-composition.md).

## Reading State From Views

- `viewModel.member` (and `scoped.member`) reads through the projection with fine-grained observation. It also registers the root, so a wholesale replacement re-renders the reader.
- `viewModel.viewState` (and `scoped.viewState`) is the whole projection. The value itself is coarse: it re-renders on a wholesale replacement or an enum case change. Members read off it stay fine-grained, so `switch viewModel.viewState { case .loaded(let l): Text(l.title) }` re-renders on case changes and on `title` changes only.
- Scopes and bindings take key paths rooted at `State.ViewState`, so they reject `@Domain` members too.
- The raw state (`ViewModel.state`) is internal to Lattice. `TestViewModel.state` exposes it to tests.
- View-side helpers belong in `extension FooState.ViewState { … }`. Same-module code can reach `_state` there; other modules only through `@_spi(Lattice) import Lattice`.

## Observation Guarantees

These are the behaviors the test suite asserts, through the view model's commit path:

| Scenario | Guarantee |
|---|---|
| Leaf change / unrelated leaf / equal value assigned | fires / silent / silent (per-member `Equatable` gating; `State: Equatable` not required) |
| `state.badge.count += 1`, directly or via `When`'s `&state[keyPath: \.badge]` | only `badge.count` observers fire; `badge.label`, `title`, root silent |
| Wholesale replacement `state = State(...)` with different content | root fires, every leaf re-reads |
| Wholesale replacement with equal content (`areStatesEqual` available) | nothing fires; registrars preserved |
| Content-equal child rebuild `state.badge = BadgeState(same)` | silent; child `_$id` preserved |
| Child rebuilt with different content | parent `\.badge` fires; observers that walked through `badge` re-read; root silent |
| Optional child `nil → value`; then `detail?.count += 1` | fires; then leaf-only |
| `rows[0].count += 1` / `rows.append` / `rows[id:]?.count += 1` | element-only / `rows` observers / element-only |
| Enum case switch / payload edit through `When`'s case path | root fires / leaf-only, root `_$id` unchanged |
| Observer re-reads synchronously during a mutation | no crash; reads the previous committed value |
| Coarse `viewModel.badge` read then `badge.count += 1` | silent (documented coarse-vs-fine rule) |

[Fine-Grained Observation](./fine-grained-observation.md) explains why these hold.

## Equality

- `State: Equatable` is not required. Each member notifies only when its value changes; a member whose type is not `Equatable` notifies on every assignment.
- `Feature.areStatesEqual` is the state's content equality. `Feature(interactor:)` supplies `==` for an `Equatable` state, and `Feature(interactor:areStatesEqual:)` takes a custom comparison. `ViewModel` uses it to drop content-equal wholesale replacements, and `TestViewModel` uses it to compare states.

## Diagnostics

All are errors.

| Condition | Message |
|---|---|
| Applied to a class or actor | `'@FeatureState' cannot be applied to class type 'X'` (or `actor type 'X'`) |
| Generic struct or enum (reported by both roles; nothing is generated) | `'@FeatureState' cannot be applied to generic type 'X': the generated projection uses a nested protocol, which Swift does not allow inside generic types (SE-0404). Make 'X' non-generic or wrap the generic data in a non-generic state type.` |
| `@Domain` on an enum case, a `static` member, or another declaration that is not an instance property | `'@Domain' can only be applied to instance properties` |
| `@Domain` on `id` while the inheritance clause lists `Identifiable` | `'id' cannot be '@Domain' on an Identifiable state; its ViewState would not satisfy 'Identifiable'` |
| A member or nested type named `ViewState`, `_$ViewStateTypes` or `_$ViewStateWitness`, or a property or case named `_state` | `'X' is reserved by '@FeatureState'` |
| `@ObservationIgnored` or `@ObservationTracked` on a member | `'@X' cannot be used in '@FeatureState'`, with a rename fix-it |

After a reserved-name error no `ViewState` is generated and only the `Observation.Observable` conformance is added. After the `@Domain id` error the unavailable `id` stub is left out. Both avoid cascading errors.

## Limitations

- Generic state types are unsupported, because nested protocols cannot live in generic types. Wrap the generic data in a non-generic state type.
- Methods, and members declared in extensions of the state, are not part of `ViewState`. View-side helpers belong in `extension FooState.ViewState { … }`, where `_state` is reachable within the module.
- Same-module code can read `viewModel.viewState._state`. The underscore is the convention there; `@_spi(Lattice)` is the cross-module guard.
- `Sendable` on `ViewState` follows the state's inheritance clause only. A conformance added in an extension elsewhere needs a manual `extension FooState.ViewState: Sendable {}`.
- `ForEach` over `Array`-backed scopes re-finds elements by id per read (O(n)); use `IdentifiedArrayOf` for O(1).
- Compile cost is about 8 ms per `@FeatureState` type, including plugin spawn.
- A multi-binding stored `var` (`var a = 0, b = 0`) is rejected by the observation accessor macro, which supports one variable per declaration. Multi-binding `let`s are projected per binding.
- Multi-payload enum cases never fire the root on a content change. A case such as `failed(message:retryCount:)` gets the stable `_$inert` identity of a payload-less case, so `.failed("a", 1) → .failed("b", 2)` commits silently and a `switch viewModel.viewState` that reads the payload renders stale data. Single-payload cases are not affected. This gap is known and deferred; give such a case a single payload (for example a `@FeatureState` struct) when its content changes must reach views.
- Known Swift 6.4 compiler bug: a source file that holds a `@FeatureState` enum together with other macro-annotated declarations (other `@FeatureState` types, `@CasePathable` enums, `@Observable` classes, `@Interactor` types, …) can crash the compiler with a segfault in `TypeCheckPrimaryFileRequest`, apparently from type-checking the extensions that the attached macros on the generated `ViewState` declarations synthesize. Declare each `@FeatureState` enum, `@CasePathable` or not, in its own file with no other macro-annotated declaration. Files whose `@FeatureState` types are all structs are not affected. This is a temporary layout rule that works around the compiler bug, not a design choice; the repro is referenced from §11 of the [plan](./plans/unified-feature-state.md#11-references).

## Related Specs

- [ViewModel](./view-model.md)
- [Macros](./macros.md)
- [Fine-Grained Observation](./fine-grained-observation.md)
- [Scoped View Composition](./scoped-view-composition.md)
- [Enum-Case Scoping](./enum-case-scoping.md)
- [Unified Feature State plan](./plans/unified-feature-state.md)

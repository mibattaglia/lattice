import Observation

/// Generates conformance to the ``Interactor`` protocol.
///
/// Apply this macro to a struct to make it an interactor:
///
/// ```swift
/// @Interactor<CounterState, CounterAction>
/// struct CounterInteractor: Sendable {
///     var body: some InteractorOf<Self> {
///         Interact(initialValue: CounterState()) { state, action in
///             // Handle actions
///             return .state
///         }
///     }
/// }
/// ```
///
/// The macro generates:
/// - `typealias State`
/// - `typealias Action`
/// - Protocol conformance to `Interactor`
@attached(
    member,
    names:
        named(body),
    named(Action),
    named(State)
)
@attached(memberAttribute)
@attached(extension, conformances: Interactor)
public macro Interactor<State, Action>() = #externalMacro(module: "LatticeMacros", type: "InteractorMacro")

/// Makes a struct or enum a feature's state: every stored member is observation-tracked, and a
/// nested `ViewState` projection exposes the members views may read.
///
/// ```swift
/// @FeatureState
/// struct CounterState: Equatable, Sendable {
///     var count = 0
///     @Domain var lastUpdatedAt: Date?
///     var countText: String { "\(count)" }
/// }
/// ```
///
/// `CounterState.ViewState` forwards `count` and `countText`; `lastUpdatedAt` is unavailable
/// to views but stays tracked, so `countText`-style computed members re-render when it changes.
@attached(
    member,
    names: named(_$id), named(_$observationRegistrar), named(_$willModify), named(shouldNotifyObservers),
    named(ViewState), named(_$ViewStateTypes), named(_$ViewStateWitness)
)
@attached(memberAttribute)
@attached(extension, conformances: FeatureState, Observable)
public macro FeatureState() = #externalMacro(module: "LatticeMacros", type: "FeatureStateMacro")

/// Marks a property as domain-only: tracked for observation, absent from `ViewState`.
@attached(peer)
public macro Domain() = #externalMacro(module: "LatticeMacros", type: "DomainMacro")

// Applied by @FeatureState to the generated ViewState. Overloads are selected by the compiler
// from the state's actual conformances (type-checked macro arguments).
@attached(extension, conformances: Identifiable)
public macro _IdentifiableIfPossible<T: Identifiable>(_: T.Type) =
    #externalMacro(module: "LatticeMacros", type: "IdentifiableIfPossibleMacro")
@attached(extension)
public macro _IdentifiableIfPossible<T>(_: T.Type) = #externalMacro(module: "LatticeMacros", type: "NoOpExtensionMacro")

@attached(extension, conformances: Equatable, names: named(==))
public macro _EquatableIfPossible<T: Equatable>(_: T.Type) =
    #externalMacro(module: "LatticeMacros", type: "EquatableIfPossibleMacro")
@attached(extension)
public macro _EquatableIfPossible<T>(_: T.Type) = #externalMacro(module: "LatticeMacros", type: "NoOpExtensionMacro")

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_))
public macro ObservationStateTracked() =
    #externalMacro(module: "LatticeMacros", type: "ObservationStateTrackedMacro")

@attached(accessor, names: named(willSet))
public macro ObservationStateIgnored() =
    #externalMacro(module: "LatticeMacros", type: "ObservationStateIgnoredMacro")

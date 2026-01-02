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
/// - `typealias DomainState`
/// - `typealias Action`
/// - Protocol conformance to `Interactor`
@attached(
    member,
    names:
        named(body),
    named(Action),
    named(DomainState)
)
@attached(memberAttribute)
@attached(extension, conformances: Interactor)
public macro Interactor() = #externalMacro(module: "UnoArchitectureMacros", type: "InteractorMacro")

/// Generates conformance to the ``ViewStateReducer`` protocol.
///
/// Apply this macro to a struct to make it a view state reducer:
///
/// ```swift
/// @ViewStateReducer<CounterDomainState, CounterViewState>
/// struct CounterViewStateReducer: Sendable {
///     var body: some ViewStateReducerOf<Self> {
///         BuildViewState { domainState in
///             CounterViewState(count: domainState.count)
///         }
///     }
/// }
/// ```
///
/// The macro generates:
/// - `typealias DomainState`
/// - `typealias ViewState`
/// - Protocol conformance to `ViewStateReducer`
@attached(
    member,
    names:
        named(body),
    named(DomainState),
    named(ViewState)
)
@attached(memberAttribute)
@attached(extension, conformances: ViewStateReducer)
public macro ViewStateReducer() = #externalMacro(module: "UnoArchitectureMacros", type: "ViewStateReducerMacro")

/// Defines and implements conformance of the Observable protocol.
@attached(extension, conformances: Observable, ObservableState)
@attached(
    member, names: named(_$id), named(_$observationRegistrar), named(_$willModify),
    named(shouldNotifyObservers))
@attached(memberAttribute)
public macro ObservableState() =
    #externalMacro(module: "UnoArchitectureMacros", type: "ObservableStateMacro")

@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_))
public macro ObservationStateTracked() =
    #externalMacro(module: "UnoArchitectureMacros", type: "ObservationStateTrackedMacro")

@attached(accessor, names: named(willSet))
public macro ObservationStateIgnored() =
    #externalMacro(module: "UnoArchitectureMacros", type: "ObservationStateIgnoredMacro")

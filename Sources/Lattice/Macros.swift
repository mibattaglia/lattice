/// Generates conformance to the ``Interactor`` protocol.
///
/// Apply this macro to a struct to make it an interactor:
///
/// ```swift
/// @Interactor<CounterState, CounterAction>
/// struct CounterInteractor {
///     var body: some InteractorOf<Self> {
///         Interact { state, action in
///             // Handle actions
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
public macro Interactor<DomainState, Action>() = #externalMacro(module: "LatticeMacros", type: "InteractorMacro")

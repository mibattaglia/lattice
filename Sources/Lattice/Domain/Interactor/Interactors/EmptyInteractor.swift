import Foundation

/// An interactor that does nothing — ignores all actions.
///
/// Use this for conditional interactor composition where sometimes no processing is needed.
///
/// ## Usage
///
/// ```swift
/// var body: some InteractorOf<Self> {
///     if enableLogging {
///         LoggingInteractor()
///     } else {
///         EmptyInteractor()
///     }
/// }
/// ```
public struct EmptyInteractor<State, Action>: Interactor {
    public typealias DomainState = State
    public typealias Action = Action

    /// Creates an empty interactor.
    public init() {}

    public var body: some InteractorOf<Self> { self }

    public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {}
}

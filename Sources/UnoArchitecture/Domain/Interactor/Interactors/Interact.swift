import Combine
import Foundation

/// A primitive used *inside* an ``Interactor``'s ``Interactor/body-swift.property`` for
/// handling incoming **actions** and emitting new **state** via an ``Emission``.
///
/// ``Interact`` lets you describe synchronous state transitions imperatively.
///
/// You typically create an ``Interact`` directly in an interactor's `body`:
///
/// ```swift
/// @Interactor<MyDomainState, MyEvent>
/// struct MyInteractor: Interactor {
///     var body: some InteractorOf<Self> {
///         Interact(initialValue: .loading) { state, event in
///             switch event {
///             case .incrementCount:
///                 state.count += 1
///                 return .state
///             case .load:
///                 return .perform {
///                     // hit an API
///                     let apiResult = try await myApiService.fetchCount()
///                     return MyDomainState.success(count: apiResult.count)
///                 }
///             case .syncWithOther: // or some other imaginary value over time event
///                 return .observe { currentState in
///                     myCachePublisher
///                         .map { cacheState in
///                             currentState.lastFetchedAt = cacheState.lastFetchedAt
///                         }
///                         .eraseToAnyPublisher()
///                 }
///             }
///         }
///     }
/// }
/// ```
///
/// While ``Interact`` is most commonly used this way, it can also be combined with higher-order
/// interactors via ``InteractorBuilder`` to model more complex behavior.
public struct Interact<State, Action>: Interactor {
    private let initialValue: State
    private let handler: (inout State, Action) -> Emission<State>

    /// Creates an ``Interact`` with an initial state and reducer closure.
    ///
    /// - Parameters:
    ///   - initialValue: The starting state fed to the downstream publisher.
    ///   - handler: A reducer that mutates `inout` `State` in response to an `Action` and returns
    ///     an ``Emission`` that dictates how the new state should be published.
    public init(
        initialValue: State,
        handler: @escaping (inout State, Action) -> Emission<State>
    ) {
        self.initialValue = initialValue
        self.handler = handler
    }

    public var body: some Interactor<State, Action> {
        self
    }

    /// Implements ``Interactor/interact(_:)`` by wiring the upstream actions through a feedback
    /// loop powered by ``Combine``'s `.feedback` operator (see ``Combine/Publisher/feedback(initialState:handler:)``).
    public func interact(_ upstream: AnyPublisher<Action, Never>) -> AnyPublisher<State, Never> {
        upstream
            .feedback(initialState: initialValue, handler: handler)
            .eraseToAnyPublisher()
    }
}

import CasePaths
import Combine
import Foundation

/// An ``Interactor`` that embeds a child interactor in a parent domain.
///
/// ``When`` allows you to transform a parent domain into a child domain, run a child
/// interactor on that subset domain, and emit the results as parent actions. This is an important
/// tool for breaking down large features into smaller units and then piecing them together.
///
/// You hand ``When`` 3 pieces of data for it to do its job:
///
/// * A writable key path that identifies the child state inside the parent state.
/// * A case path that identifies the child actions inside the parent actions.
/// * A case path that creates parent actions from child state updates.
///
/// For example, given the basic scaffolding of child interactor:
///
/// ```swift
/// struct ChildInteractor: Interactor {
///   // ...
/// }
/// ```
///
/// A parent interactor with a domain that holds onto the child domain can use
/// ``When`` to embed the child interactor in its ``Interactor/body-swift.property``:
///
/// ```swift
/// struct ParentInteractor: Interactor {
///   var body: some InteractorOf<Self> {
///     When(
///       stateIs: \.child,
///       actionIs: \.child,
///       stateAction: \.childStateChanged
///     ) {
///       ChildInteractor()
///     }
///     Interact(initialValue: ParentState()) { state, action in
///       // Additional parent logic and behavior
///     }
///   }
/// }
/// ```
extension Interactors {
    public struct When<ParentState, ParentAction, Child: Interactor>: Interactor {
        enum StatePath {
            case keyPath(WritableKeyPath<ParentState, Child.DomainState>)
            case casePath(AnyCasePath<ParentState, Child.DomainState>)
        }

        let toChildState: StatePath

        let toChildAction: AnyCasePath<ParentAction, Child.Action>

        let toStateAction: AnyCasePath<ParentAction, Child.DomainState>

        let child: Child

        init(
            toChildState: StatePath,
            toChildAction: AnyCasePath<ParentAction, Child.Action>,
            toStateAction: AnyCasePath<ParentAction, Child.DomainState>,
            child: Child
        ) {
            self.toChildState = toChildState
            self.toChildAction = toChildAction
            self.toStateAction = toStateAction
            self.child = child
        }

        /// Initializes a ``When`` interactor that routes child actions to a child interactor and
        /// propagates state updates back to the parent.
        ///
        /// Use this initializer when the child state is a **struct property** of the parent state.
        /// This is the most common composition pattern for features that are always present in the
        /// parent domain.
        ///
        /// ```swift
        /// var body: some InteractorOf<Self> {
        ///   When(
        ///     stateIs: \.profile,
        ///     actionIs: \.profile,
        ///     stateAction: \.profileStateChanged
        ///   ) {
        ///     Profile()
        ///   }
        ///   When(
        ///     stateIs: \.settings,
        ///     actionIs: \.settings,
        ///     stateAction: \.settingsStateChanged
        ///   ) {
        ///     Settings()
        ///   }
        ///   // ...
        /// }
        /// ```
        ///
        /// - Parameters:
        ///   - toChildState: A writable key path from parent state to a property containing child state.
        ///   - toChildAction: A case path from parent action to a case containing child actions.
        ///   - toStateAction: A case path that creates parent actions from child state updates.
        ///   - child: An interactor that will be invoked with child actions against child state.
        public init<ChildState, ChildAction>(
            stateIs toChildState: WritableKeyPath<ParentState, ChildState>,
            actionIs toChildAction: CaseKeyPath<ParentAction, ChildAction>,
            stateAction toStateAction: CaseKeyPath<ParentAction, ChildState>,
            @InteractorBuilder<ChildState, ChildAction> run child: () -> Child
        ) where ChildState == Child.DomainState, ChildAction == Child.Action {
            self.init(
                toChildState: .keyPath(toChildState),
                toChildAction: AnyCasePath(toChildAction),
                toStateAction: AnyCasePath(toStateAction),
                child: child()
            )
        }

        /// Initializes a ``When`` interactor that routes child actions to a child interactor and
        /// propagates state updates back to the parent.
        ///
        /// Use this initializer when the child state is an **enum case** of the parent state.
        /// This pattern is useful for mutually-exclusive features (e.g., logged in vs. logged out).
        /// The child interactor only receives actions when the parent state matches its case.
        ///
        /// ```swift
        /// var body: some InteractorOf<Self> {
        ///   When(
        ///     stateIs: \.loggedIn,
        ///     actionAction: \.loggedIn,
        ///     stateAction: \.loggedInStateChanged
        ///   ) {
        ///     LoggedIn()
        ///   }
        ///   When(
        ///     stateIs: \.loggedOut,
        ///     actionAction: \.loggedOut,
        ///     stateAction: \.loggedOutStateChanged
        ///   ) {
        ///     LoggedOut()
        ///   }
        /// }
        /// ```
        ///
        /// - Parameters:
        ///   - toChildState: A case path from parent state to a case containing child state.
        ///   - toChildAction: A case path from parent action to a case containing child actions.
        ///   - toStateAction: A case path that creates parent actions from child state updates.
        ///   - child: An interactor that will be invoked with child actions against child state.
        public init<ChildState, ChildAction>(
            stateIs toChildState: CaseKeyPath<ParentState, ChildState>,
            actionAction toChildAction: CaseKeyPath<ParentAction, ChildAction>,
            stateAction toStateAction: CaseKeyPath<ParentAction, ChildState>,
            @InteractorBuilder<ChildState, ChildAction> run child: () -> Child
        ) where ChildState == Child.DomainState, ChildAction == Child.Action {
            self.init(
                toChildState: .casePath(AnyCasePath(toChildState)),
                toChildAction: AnyCasePath(toChildAction),
                toStateAction: AnyCasePath(toStateAction),
                child: child()
            )
        }

        public typealias DomainState = ParentAction
        public typealias Action = ParentAction

        public var body: some Interactor<ParentAction, ParentAction> { self }

        public func interact(
            _ upstream: AnyPublisher<ParentAction, Never>
        ) -> AnyPublisher<ParentAction, Never> {
            // Subject to drive child interactor while maintaining state continuity
            let childActionSubject = PassthroughSubject<Child.Action, Never>()

            // Use CurrentValueSubject as a reference-type state holder for synchronous access
            let stateHolder = CurrentValueSubject<Child.DomainState?, Never>(nil)
            let cancellable: AnyCancellable? = childActionSubject
                .interact(with: self.child)
                .sink { stateHolder.send($0) }

            // Capture initial state after subscription is established
            let initialStateAction: AnyPublisher<ParentAction, Never>
            if let initialState = stateHolder.value {
                initialStateAction = Just(self.toStateAction.embed(initialState)).eraseToAnyPublisher()
            } else {
                initialStateAction = Empty().eraseToAnyPublisher()
            }

            // Process upstream with deterministic ordering:
            // original action first, then any resulting state changes
            return upstream
                .flatMap { [toChildAction, toStateAction] action -> AnyPublisher<ParentAction, Never> in
                    var outputs: [ParentAction] = [action]

                    if let childAction = toChildAction.extract(from: action) {
                        childActionSubject.send(childAction)
                        if let state = stateHolder.value {
                            outputs.append(toStateAction.embed(state))
                        }
                    }

                    return outputs.publisher.eraseToAnyPublisher()
                }
                .prepend(initialStateAction)
                .handleEvents(receiveCancel: { cancellable?.cancel() })
                .eraseToAnyPublisher()
        }
    }
}

public typealias When<ParentState, ParentAction, Child: Interactor> = Interactors.When<ParentState, ParentAction, Child>

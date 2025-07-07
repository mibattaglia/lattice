import CasePaths
import Combine
import Foundation

/// An ``Interactor`` that embeds a child interactor in a parent domain.
///
/// ``Scope`` allows you to transform a parent domain into a child domain, run a child
/// interactor on that subset domain, and emit the results as parent actions. This is an important
/// tool for breaking down large features into smaller units and then piecing them together.
///
/// You hand ``Scope`` 3 pieces of data for it to do its job:
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
/// ``Scope`` to embed the child interactor in its ``Interactor/body-swift.property``:
///
/// ```swift
/// struct ParentInteractor: Interactor {
///   var body: some InteractorOf<Self> {
///     Scope(
///       state: \.child,
///       action: \.child,
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
    public struct Scope<ParentState, ParentAction, Child: Interactor>: Interactor {
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

        /// Initializes a scope that runs the given child interactor against a slice of parent state and
        /// actions.
        ///
        /// Useful for combining child interactors into a parent.
        ///
        /// ```swift
        /// var body: some InteractorOf<Self> {
        ///   Scope(
        ///     state: \.profile,
        ///     action: \.profile,
        ///     stateAction: \.profileStateChanged
        ///   ) {
        ///     Profile()
        ///   }
        ///   Scope(
        ///     state: \.settings,
        ///     action: \.settings,
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
            state toChildState: WritableKeyPath<ParentState, ChildState>,
            action toChildAction: CaseKeyPath<ParentAction, ChildAction>,
            stateAction toStateAction: CaseKeyPath<ParentAction, ChildState>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
        ) where ChildState == Child.DomainState, ChildAction == Child.Action {
            self.init(
                toChildState: .keyPath(toChildState),
                toChildAction: AnyCasePath(toChildAction),
                toStateAction: AnyCasePath(toStateAction),
                child: child()
            )
        }

        /// Initializes a scope that runs the given child interactor against a slice of parent state and
        /// actions.
        ///
        /// Useful for combining interactors of mutually-exclusive enum state.
        ///
        /// ```swift
        /// var body: some InteractorOf<Self> {
        ///   Scope(
        ///     state: \.loggedIn,
        ///     action: \.loggedIn,
        ///     stateAction: \.loggedInStateChanged
        ///   ) {
        ///     LoggedIn()
        ///   }
        ///   Scope(
        ///     state: \.loggedOut,
        ///     action: \.loggedOut,
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
            state toChildState: CaseKeyPath<ParentState, ChildState>,
            action toChildAction: CaseKeyPath<ParentAction, ChildAction>,
            stateAction toStateAction: CaseKeyPath<ParentAction, ChildState>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
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
            // Filter actions for the child
            let childActions =
                upstream
                .compactMap { action in
                    self.toChildAction.extract(from: action)
                }

            // Run child interactor and convert child state updates to parent actions
            let childStateActions =
                childActions
                .interact(with: self.child)
                .map { childState in
                    self.toStateAction.embed(childState)
                }

            // Pass through all original actions and add child state change actions
            return Publishers.Merge(upstream, childStateActions)
                .eraseToAnyPublisher()
        }
    }
}

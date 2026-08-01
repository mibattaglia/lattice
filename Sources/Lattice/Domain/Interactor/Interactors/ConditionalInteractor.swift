import Foundation

/// Branch identity for `Interactors.Conditional` GraphPath components.
enum ConditionalBranch: Hashable {
    case first
    case second
}

extension Interactors {
    /// An interactor that conditionally delegates to one of two child interactors.
    ///
    /// `Conditional` is used internally by `InteractorBuilder` for `if-else` statements:
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     if useFeatureA {
    ///         FeatureAInteractor()
    ///     } else {
    ///         FeatureBInteractor()
    ///     }
    /// }
    /// ```
    public enum Conditional<First: Interactor, Second: Interactor<First.DomainState, First.Action>>: Interactor,
        @unchecked Sendable
    where First.DomainState: Sendable, First.Action: Sendable {
        case first(First)
        case second(Second)

        public var body: some Interactor<First.DomainState, First.Action> { self }

        public func interact(state: inout First.DomainState, action: First.Action) -> Emission<First.Action> {
            switch self {
            case .first(let first):
                return first.interact(state: &state, action: action)
            case .second(let second):
                return second.interact(state: &state, action: action)
            }
        }

        /// Each branch appends a branch-tag `GraphPath` component, so the two branches occupy
        /// disjoint task-storage buckets. The composition tree is static: the branch taken is
        /// fixed when `body` is first evaluated and must not change for the lifetime of the
        /// host.
        public func interact(
            state: inout First.DomainState,
            action: First.Action,
            effects: Effects<First.DomainState, First.Action>
        ) {
            switch self {
            case .first(let first):
                first.interact(
                    state: &state,
                    action: action,
                    effects: effects.appending(.id(ConditionalBranch.first))
                )
            case .second(let second):
                second.interact(
                    state: &state,
                    action: action,
                    effects: effects.appending(.id(ConditionalBranch.second))
                )
            }
        }
    }
}

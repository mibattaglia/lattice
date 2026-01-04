import Foundation

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

        public func interact(state: inout First.DomainState, action: First.Action) -> Emission<First.DomainState> {
            switch self {
            case .first(let first):
                return first.interact(state: &state, action: action)
            case .second(let second):
                return second.interact(state: &state, action: action)
            }
        }
    }
}

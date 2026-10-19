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
    public enum Conditional<First: Interactor, Second: Interactor<First.State, First.Action>>: Interactor {
        case first(First)
        case second(Second)

        public var body: some Interactor<First.State, First.Action> { self }

        public func interact(
            state: inout First.State,
            action: First.Action,
            effects: Effects<First.State, First.Action>
        ) {
            switch self {
            case .first(let first):
                first.interact(state: &state, action: action, effects: effects)
            case .second(let second):
                second.interact(state: &state, action: action, effects: effects)
            }
        }
    }
}

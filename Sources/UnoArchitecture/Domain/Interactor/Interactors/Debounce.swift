// TODO: Debounce needs redesign for action-based model
// The Debouncer needs to return the action value, not Task<Void, Never>
// See: thoughts/shared/plans/2026-01-04_emission-action-migration.md "Open Questions"

//extension Interactors {
//    public struct Debounce<C: Clock, Child: Interactor & Sendable>: Interactor, Sendable
//    where Child.DomainState: Sendable, Child.Action: Sendable, C.Duration: Sendable {
//        public typealias DomainState = Child.DomainState
//        public typealias Action = Child.Action
//
//        private let child: Child
//        private let debouncer: Debouncer<C>
//
//        public init(for duration: C.Duration, clock: C, child: () -> Child) {
//            self.child = child()
//            self.debouncer = Debouncer(for: duration, clock: clock)
//        }
//
//        public var body: some InteractorOf<Self> { self }
//
//        public func interact(state: inout DomainState, action: Action) -> Emission<Action> {
//            // TODO: Needs debouncer to return Action?
//            .none
//        }
//    }
//}
//
//extension Interactors.Debounce where C == ContinuousClock {
//    public init(for duration: Duration, child: () -> Child) {
//        self.init(for: duration, clock: ContinuousClock(), child: child)
//    }
//}
//
//public typealias DebounceInteractor<C: Clock & Sendable, Child: Interactor & Sendable> = Interactors.Debounce<C, Child>

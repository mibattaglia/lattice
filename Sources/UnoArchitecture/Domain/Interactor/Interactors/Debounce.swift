import Combine
import CombineSchedulers
import Foundation

extension Interactors {
    public struct Debounce<Child: Interactor>: Interactor {
        public typealias DomainState = Child.DomainState
        public typealias Action = Child.Action

        private let child: Child
        private let duration: DispatchQueue.SchedulerTimeType.Stride
        private let scheduler: AnySchedulerOf<DispatchQueue>

        public init(
            for duration: DispatchQueue.SchedulerTimeType.Stride,
            scheduler: AnySchedulerOf<DispatchQueue>,
            child: () -> Child
        ) {
            self.duration = duration
            self.scheduler = scheduler
            self.child = child()
        }

        public var body: some InteractorOf<Self> { self }

        public func interact(
            _ upstream: AnyPublisher<Action, Never>
        ) -> AnyPublisher<DomainState, Never> {
            upstream
                .debounce(for: duration, scheduler: scheduler)
                .interact(with: child)
                .eraseToAnyPublisher()
        }
    }
}

import Foundation

public struct EmptyInteractor<State: Sendable, Action: Sendable>: Interactor, Sendable {
    public typealias DomainState = State
    public typealias Action = Action

    private let completeImmediately: Bool

    public init(completeImmediately: Bool = true) {
        self.completeImmediately = completeImmediately
    }

    public var body: some InteractorOf<Self> { self }

    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
        AsyncStream {
            if completeImmediately {
                $0.finish()
            } else {
                let task = Task {
                    for await _ in upstream { }
                }
                $0.onTermination = { _ in task.cancel() }
                $0.finish()
            }
        }
    }
}

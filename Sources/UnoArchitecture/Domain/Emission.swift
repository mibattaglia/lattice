import Combine
import Foundation

/// A descriptor that tells an ``Interactor`` _how_ to emit domain state downstream.
///
/// An ``Emission`` can
/// 1. **Immediately** push the current state (`state`).
/// 2. **Perform asynchronous work** that eventually returns a new state (`perform(work:)`).
/// 3. **Observe** an arbitrary publisher built from the current ``DynamicState`` (`observe(_:)`).
///
/// You typically create an ``Emission`` inside an ``Interactor``'s interact closure to
/// describe the side-effects that should happen in response to an incoming action.
public struct Emission<State> {
    /// The underlying kind of emission to perform.
    public enum Kind {
        /// Immediately forward state as-is.
        case state
        /// Execute an asynchronous unit of work and publish its resulting state.
        case perform(work: @Sendable () async -> State)
        /// Build and subscribe to a publisher that can feed state changes over time.
        /// - Parameter publisher: A closure that receives a ``DynamicState`` proxy and must
        ///   return a publisher of state values.
        case observe(publisher: (DynamicState<State>) -> AnyPublisher<State, Never>)

    }

    let kind: Kind

    /// Creates an immediate ``Kind/state`` emission.
    public static var state: Emission {
        Emission(kind: .state)
    }

    /// Creates a ``Kind/perform(work:)`` emission that executes the given asynchronous work.
    ///
    /// - Parameter work: An async closure that produces a new `State` value.
    /// - Returns: A new ``Emission`` instance.
    public static func perform(
        work: @Sendable @escaping () async -> State
    ) -> Emission {
        Emission(kind: .perform(work: work))
    }

    /// Creates a ``Kind/observe(publisher:)`` emission that subscribes to the publisher returned
    /// by `builder`.
    ///
    /// - Parameter builder: A closure that receives the current ``DynamicState`` and should return
    ///   a publisher emitting subsequent `State` values.
    /// - Returns: A new ``Emission`` instance.
    public static func observe(
        _ builder: @escaping (DynamicState<State>) -> AnyPublisher<State, Never>
    ) -> Emission {
        Emission(kind: .observe(publisher: builder))
    }
}

extension Emission {
    public static func stream<T>(
        _ builder: @escaping (DynamicState<State>, StreamBuilder<T>) -> AnyPublisher<State, Never>
    ) -> Emission {
        let streamBuilder = StreamBuilder<T>()
        return .observe { state in
            return builder(state, streamBuilder)
        }
    }
}

public struct StreamBuilder<T> {
    private let subject = PassthroughSubject<T, Never>()

    @discardableResult
    public func send(_ value: T) -> StreamBuilder<T> {
        subject.send(value)
        return self
    }

    public func publisher() -> AnyPublisher<T, Never> {
        subject.eraseToAnyPublisher()
    }
}

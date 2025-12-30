import Foundation

/// A descriptor that tells an ``Interactor`` _how_ to emit domain state downstream.
public struct Emission<State: Sendable>: Sendable {
    public enum Kind: Sendable {
        /// Immediately forward state as-is.
        case state

        /// Execute an asynchronous unit of work and emit state via the `Send` callback.
        /// The closure receives `DynamicState` for reading fresh state and `Send` for emitting updates.
        case perform(work: @Sendable (DynamicState<State>, Send<State>) async -> Void)

        /// Observe a stream, emitting state for each element via the `Send` callback.
        /// The closure receives `DynamicState` for reading fresh state and `Send` for emitting updates.
        case observe(stream: @Sendable (DynamicState<State>, Send<State>) async -> Void)
    }

    let kind: Kind

    public static var state: Emission {
        Emission(kind: .state)
    }

    public static func perform(
        _ work: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .perform(work: work))
    }

    public static func observe(
        _ stream: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .observe(stream: stream))
    }
}

import Foundation

/// A descriptor that tells an ``Interactor`` _how_ to emit domain state downstream.
///
/// `Emission` is returned from the handler closure in ``Interact`` to specify whether state
/// should be emitted synchronously or via an asynchronous effect.
///
/// ## Usage
///
/// There are four emission types:
///
/// ### `.state` - Synchronous Emission
///
/// Emits the current state immediately after the handler returns:
///
/// ```swift
/// Interact(initialValue: State()) { state, action in
///     state.count += 1
///     return .state
/// }
/// ```
///
/// ### `.perform` - One-Shot Async Work
///
/// Executes async work and emits state via the `send` callback:
///
/// ```swift
/// return .perform { state, send in
///     let data = try await api.fetchData()
///     var currentState = await state.current
///     currentState.data = data
///     currentState.isLoading = false
///     await send(currentState)
/// }
/// ```
///
/// ### `.observe` - Long-Running Observation
///
/// Observes an async stream, emitting state for each element:
///
/// ```swift
/// return .observe { state, send in
///     for await location in locationManager.locations {
///         var currentState = await state.current
///         currentState.location = location
///         await send(currentState)
///     }
/// }
/// ```
///
/// ### `.merge` - Combine Multiple Emissions
///
/// Combines multiple emissions into one, used by higher-order interactors:
///
/// ```swift
/// return .merge([emission1, emission2])
/// ```
///
/// - Note: Both `.perform` and `.observe` receive a ``DynamicState`` for reading the latest
///   state and a ``Send`` callback for emitting updates.
public struct Emission<State: Sendable>: Sendable {
    /// The kind of emission to perform.
    public enum Kind: Sendable {
        /// Immediately forward state as-is.
        case state

        /// Execute an asynchronous unit of work and emit state via the `Send` callback.
        ///
        /// The closure receives:
        /// - `DynamicState`: For reading the current state at any point during execution
        /// - `Send`: For emitting state updates back to the interactor
        case perform(work: @Sendable (DynamicState<State>, Send<State>) async -> Void)

        /// Observe a stream, emitting state for each element via the `Send` callback.
        ///
        /// The closure receives:
        /// - `DynamicState`: For reading the current state at any point during execution
        /// - `Send`: For emitting state updates back to the interactor
        ///
        /// - Note: Semantically equivalent to `.perform` but indicates long-running observation.
        case observe(stream: @Sendable (DynamicState<State>, Send<State>) async -> Void)

        /// Combine multiple emissions into one.
        ///
        /// Used by higher-order interactors like ``Interactors/Merge`` to combine
        /// the emissions from multiple child interactors.
        case merge([Emission<State>])
    }

    let kind: Kind

    /// Creates an emission that immediately forwards the current state.
    public static var state: Emission {
        Emission(kind: .state)
    }

    /// Creates an emission that executes async work and emits state via callback.
    ///
    /// - Parameter work: An async closure that receives `DynamicState` for reading state
    ///   and `Send` for emitting updates.
    /// - Returns: An emission configured for one-shot async work.
    public static func perform(
        _ work: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .perform(work: work))
    }

    /// Creates an emission that observes an async stream and emits state for each element.
    ///
    /// - Parameter stream: An async closure that receives `DynamicState` for reading state
    ///   and `Send` for emitting updates. Typically used for long-running observations.
    /// - Returns: An emission configured for stream observation.
    public static func observe(
        _ stream: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .observe(stream: stream))
    }

    /// Creates an emission that combines multiple emissions.
    ///
    /// - Parameter emissions: The emissions to combine.
    /// - Returns: An emission that will execute all child emissions.
    public static func merge(_ emissions: [Emission<State>]) -> Emission {
        Emission(kind: .merge(emissions))
    }

    /// Combines this emission with another.
    ///
    /// - Parameter other: The emission to merge with.
    /// - Returns: A merged emission containing both.
    public func merging(with other: Emission<State>) -> Emission<State> {
        .merge([self, other])
    }
}

import Foundation

/// Describes how an interactor emits actions after processing an action.
///
/// `Emission` is returned from ``Interactor/interact(state:action:)`` to specify
/// whether additional actions should be emitted, either synchronously or via async effects.
///
/// ## Emission Types
///
/// ### `.none` - No Action
///
/// No action to emit. Used when state was mutated synchronously but no async work needed:
///
/// ```swift
/// case .increment:
///     state.count += 1
///     return .none
/// ```
///
/// ### `.action` - Immediate Action
///
/// Emit a single action immediately. Processed synchronously before returning:
///
/// ```swift
/// case .buttonTapped:
///     return .action(.startLoading)
/// ```
///
/// ### `.perform` - One-Shot Async Work
///
/// Executes async work and returns an action:
///
/// ```swift
/// case .fetchData:
///     state.isLoading = true
///     return .perform {
///         let data = try await api.fetchData()
///         return .dataLoaded(data)
///     }
/// ```
///
/// ### `.observe` - Long-Running Observation
///
/// Observes an async stream, emitting an action for each element:
///
/// ```swift
/// case .startLocationTracking:
///     return .observe {
///         AsyncStream { continuation in
///             for await location in locationManager.locations {
///                 continuation.yield(.locationUpdated(location))
///             }
///             continuation.finish()
///         }
///     }
/// ```
///
/// ### `.merge` - Combine Multiple Emissions
///
/// Combines multiple emissions into one, used by higher-order interactors:
///
/// ```swift
/// return .merge([emission1, emission2])
/// ```
public struct Emission<Action: Sendable>: Sendable {
    /// The kind of emission to perform.
    public enum Kind: Sendable {
        /// No action to emit.
        case none

        /// Emit a single action immediately.
        case action(Action)

        /// Execute async work and return an action.
        ///
        /// The work closure returns `Action?`. If `nil`, no action is emitted
        /// (useful for cancelled operations or error handling).
        case perform(work: @Sendable () async -> Action?)

        /// Observe an async stream of actions.
        ///
        /// The stream closure returns `AsyncStream<Action>`. Each action in the
        /// stream is processed through the interactor.
        case observe(stream: @Sendable () async -> AsyncStream<Action>)

        /// Combine multiple emissions into one.
        ///
        /// Used by higher-order interactors like ``Interactors/Merge`` to combine
        /// the emissions from multiple child interactors.
        case merge([Emission<Action>])
    }

    let kind: Kind

    /// No action to emit.
    public static var none: Emission {
        Emission(kind: .none)
    }

    /// Emit a single action immediately.
    ///
    /// The action is processed synchronously by the interactor before returning
    /// control to the caller.
    ///
    /// - Parameter action: The action to emit.
    /// - Returns: An emission that immediately emits the action.
    public static func action(_ action: Action) -> Emission {
        Emission(kind: .action(action))
    }

    /// Execute async work and emit the resulting action.
    ///
    /// ```swift
    /// return .perform {
    ///     let data = await api.fetch()
    ///     return .fetchCompleted(data)
    /// }
    /// ```
    ///
    /// Return `nil` to emit no action (e.g., for cancelled operations):
    ///
    /// ```swift
    /// return .perform {
    ///     guard !Task.isCancelled else { return nil }
    ///     let data = await api.fetch()
    ///     return .fetchCompleted(data)
    /// }
    /// ```
    ///
    /// - Parameter work: An async closure that returns an optional action.
    /// - Returns: An emission configured for one-shot async work.
    public static func perform(_ work: @escaping @Sendable () async -> Action?) -> Emission {
        Emission(kind: .perform(work: work))
    }

    /// Observe an async stream and emit each action.
    ///
    /// ```swift
    /// return .observe {
    ///     AsyncStream { continuation in
    ///         for await location in locationManager.locations {
    ///             continuation.yield(.locationUpdated(location))
    ///         }
    ///         continuation.finish()
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter stream: An async closure that returns an `AsyncStream<Action>`.
    /// - Returns: An emission configured for stream observation.
    public static func observe(_ stream: @escaping @Sendable () async -> AsyncStream<Action>) -> Emission {
        Emission(kind: .observe(stream: stream))
    }

    /// Combine multiple emissions into one.
    ///
    /// All emissions execute concurrently.
    ///
    /// - Parameter emissions: The emissions to combine.
    /// - Returns: An emission that will execute all child emissions.
    public static func merge(_ emissions: [Emission<Action>]) -> Emission {
        Emission(kind: .merge(emissions))
    }

    /// Combines this emission with another.
    ///
    /// - Parameter other: The emission to merge with.
    /// - Returns: A merged emission containing both.
    public func merging(with other: Emission<Action>) -> Emission<Action> {
        .merge([self, other])
    }
}

// MARK: - Action Mapping

extension Emission {
    /// Transforms the actions in this emission.
    ///
    /// Used by higher-order interactors like `When` to map child actions to parent actions:
    ///
    /// ```swift
    /// let childEmission = child.interact(state: &childState, action: childAction)
    /// return childEmission.map { .child($0) }
    /// ```
    ///
    /// - Parameter transform: A closure that transforms actions.
    /// - Returns: An emission with transformed actions.
    public func map<ParentAction>(
        _ transform: @escaping @Sendable (Action) -> ParentAction
    ) -> Emission<ParentAction> {
        switch kind {
        case .none:
            return .none

        case .action(let action):
            return .action(transform(action))

        case .perform(let work):
            return .perform {
                guard let action = await work() else { return nil }
                return transform(action)
            }

        case .observe(let stream):
            return .observe {
                let sourceStream = await stream()
                return AsyncStream { continuation in
                    Task {
                        for await action in sourceStream {
                            continuation.yield(transform(action))
                        }
                        continuation.finish()
                    }
                }
            }

        case .merge(let emissions):
            return .merge(emissions.map { $0.map(transform) })
        }
    }
}

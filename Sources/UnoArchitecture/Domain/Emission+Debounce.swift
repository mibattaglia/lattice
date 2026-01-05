import Foundation

extension Emission {
    /// Debounces this emission using the provided debouncer.
    ///
    /// When applied to a `.perform` emission, the work is debounced - rapid calls
    /// cancel previous pending work and only the last one executes after the quiet period.
    ///
    /// The debouncer returns `DebounceResult<Action?>` which preserves the semantic
    /// difference between:
    /// - `.executed(nil)`: work ran and chose not to emit an action
    /// - `.superseded`: work was cancelled by a newer call
    ///
    /// Both cases result in `nil` at the Emission level (no action to process),
    /// but the distinction is preserved in the debouncer for logging/debugging.
    ///
    /// ```swift
    /// case .searchTextChanged(let query):
    ///     state.query = query
    ///     return .perform {
    ///         let results = await api.search(query)
    ///         return .searchCompleted(results)
    ///     }
    ///     .debounce(using: searchDebouncer)
    /// ```
    ///
    /// - Parameter debouncer: The debouncer to use for timing and coalescing.
    /// - Returns: A debounced emission.
    public func debounce<C: Clock>(
        using debouncer: Debouncer<C, Action?>
    ) -> Emission<Action> where C.Duration: Sendable {
        switch kind {
        case .none:
            return .none

        case .action(let action):
            return .action(action)

        case .perform(let work):
            return .perform {
                let task = await debouncer.debounce {
                    await work()
                }
                switch await task.value {
                case .executed(let action):
                    return action
                case .superseded:
                    return nil
                }
            }

        case .observe:
            return self

        case .merge(let emissions):
            return .merge(emissions.map { $0.debounce(using: debouncer) })
        }
    }
}

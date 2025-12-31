import Foundation

/// A type that provides **read-only** dynamic member lookup access to the current state
/// within `.perform` and `.observe` emission handlers.
///
/// `DynamicState` enables effect closures to read the latest state value at any point
/// during their execution, ensuring they always have access to current data.
///
/// ## Usage
///
/// Access individual properties via dynamic member lookup:
///
/// ```swift
/// return .perform { state, send in
///     let currentCount = await state.count
///     let userId = await state.user.id
///     // ...
/// }
/// ```
///
/// Or access the full state:
///
/// ```swift
/// return .perform { state, send in
///     var currentState = await state.current
///     currentState.isLoading = false
///     await send(currentState)
/// }
/// ```
///
/// ## Thread Safety
///
/// State access is asynchronous because it reads from `@MainActor`-isolated storage.
/// This ensures thread-safe access to the latest value from any async context.
///
/// - Note: `DynamicState` is read-only. To emit state changes, use the ``Send`` callback.
@dynamicMemberLookup
public struct DynamicState<State>: Sendable {
    private let getCurrentState: @Sendable () async -> State

    init(getCurrentState: @escaping @Sendable () async -> State) {
        self.getCurrentState = getCurrentState
    }

    /// Returns the value at the given key path of the underlying state.
    ///
    /// - Parameter keyPath: A key path to a property of the state.
    /// - Returns: The value at the specified key path.
    public subscript<T>(dynamicMember keyPath: KeyPath<State, T>) -> T {
        get async {
            await getCurrentState()[keyPath: keyPath]
        }
    }

    /// Returns the full current state value.
    ///
    /// Use this when you need to read multiple properties or mutate a copy:
    ///
    /// ```swift
    /// var currentState = await state.current
    /// currentState.isLoading = false
    /// currentState.data = fetchedData
    /// await send(currentState)
    /// ```
    public var current: State {
        get async {
            await getCurrentState()
        }
    }
}

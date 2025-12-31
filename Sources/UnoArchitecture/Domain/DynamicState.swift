import Foundation

/// A type that provides **read-only** dynamic member lookup access to the current state
/// within an `observe` emission handler.
///
/// State access is asynchronous because it reads from actor-isolated storage,
/// ensuring thread-safe access to the latest value.
@dynamicMemberLookup
public struct DynamicState<State>: Sendable {
    private let getCurrentState: @Sendable () async -> State

    init(getCurrentState: @escaping @Sendable () async -> State) {
        self.getCurrentState = getCurrentState
    }

    /// Returns the value at the given key path of the underlying state.
    public subscript<T>(dynamicMember keyPath: KeyPath<State, T>) -> T {
        get async {
            await getCurrentState()[keyPath: keyPath]
        }
    }

    /// Returns the full current state value.
    public var current: State {
        get async {
            await getCurrentState()
        }
    }
}

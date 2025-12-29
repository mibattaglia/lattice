import Combine
import Foundation

/// A type that provides **read-only** dynamic member lookup access to the latest value of a
/// ``Combine/CurrentValueSubject`` that models your domain state.
///
/// ``DynamicState`` is primarily used by ``Emission`` publishers to give observers a convenient,
/// type-safe way of peeking at the current state while building derived publishers.  It behaves
/// similarly to Swift's dynamic member lookup on key paths, allowing you to access nested
/// properties using dot-syntax:
///
/// ```swift
/// let stateSubject = CurrentValueSubject<AppState, Never>(.initial)
/// let state = DynamicState(stream: stateSubject)
///
/// // Access a nested property
/// let isLoggedIn = state.isLoggedIn
/// ```
///
/// Because the value is read only, you cannot mutate state through ``DynamicState``.  To publish
/// state mutations use an ``Interactor`` and emit new values through the upstream publisher.
@dynamicMemberLookup
public struct DynamicState<State> {
    private let stream: CurrentValueSubject<State, Never>

    /// Creates a new ``DynamicState`` that proxies reads to the provided
    /// ``Combine/CurrentValueSubject``.
    ///
    /// - Parameter stream: A subject whose `value` represents the current domain state.
    init(stream: CurrentValueSubject<State, Never>) {
        self.stream = stream
    }

    /// Returns the value at the given key path of the underlying state.
    ///
    /// - Parameter keyPath: A key path into `State` describing the property to read.
    /// - Returns: The property's value as stored in the most recent state.
    public subscript<T>(dynamicMember keyPath: KeyPath<State, T>) -> T {
        stream.value[keyPath: keyPath]
    }

    public var wrappedValue: State {
        stream.value
    }
}

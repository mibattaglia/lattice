/// The result of a debounced operation.
///
/// `DebounceResult` distinguishes between work that executed and work that was
/// superseded by a newer call. This is important when the work's return type
/// is itself optional, as it preserves the semantic difference between
/// "work ran and returned nil" vs "work was cancelled".
///
/// ## Example
///
/// ```swift
/// let result = await debouncer.debounce { fetchData() }
/// switch result {
/// case .executed(let data):
///     // Work completed, use data
/// case .superseded:
///     // Work was cancelled by a newer call
/// }
/// ```
public enum DebounceResult<T: Sendable>: Sendable {
    /// The work executed and returned a value.
    case executed(T)

    /// The work was superseded by a newer debounce call and did not execute.
    case superseded
}

extension DebounceResult: Equatable where T: Equatable {}

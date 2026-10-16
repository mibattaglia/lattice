/// Declares an effect identity on an interactor.
///
/// The key is the declaration site, so every instance of the declaring type — including the fresh
/// instances `body` builds on each action — names the same effect. Two declarations never collide
/// (`#column` is part of the key). The key is a value; the task it names lives in the feature's
/// runtime, so nothing is stored in state.
///
/// ```swift
/// @Interactor<SearchState, SearchAction>
/// struct SearchInteractor {
///     @EffectID var search
///
///     var body: some InteractorOf<Self> {
///         Interact { state, action, effects in
///             switch action {
///             case .queryChanged(let query):
///                 state.query = query
///                 effects.perform(id: search) { … }   // replaces the previous `search` effect
///             case .cancelTapped:
///                 effects.cancel(search)
///                 state.isSearching = false
///             }
///         }
///     }
/// }
/// ```
///
/// A key is registered under the `When` scope of the handle that performs it, so the same child
/// interactor scoped twice (`When(state: \.a) { Child() }`, `When(state: \.b) { Child() }`) runs
/// two independent effects. Every specialization of a generic interactor shares one key, and two
/// instances of one child type in the same scope share one key (the second replaces the first).
@propertyWrapper
public struct EffectID {
    /// The identity of an effect: the declaration site of its `@EffectID`, its optional name and,
    /// for a per-element key (``EffectID/scoped(_:)``), the element.
    public struct Key: Hashable, CustomStringConvertible {
        let fileID: String
        let line: UInt
        let column: UInt
        let name: String?
        let element: AnyHashable?

        public var description: String {
            "\(fileID):\(line):\(column)" + (name.map { " \"\($0)\"" } ?? "") + (element.map { " [\($0)]" } ?? "")
        }
    }

    public let wrappedValue: Key

    /// The wrapper itself, for per-element keys: `$download.scoped(row.id)`.
    public var projectedValue: EffectID { self }

    /// Creates the identity declared at the call site.
    ///
    /// - Parameter name: An optional name, shown in the key's description.
    public init(_ name: String? = nil, fileID: StaticString = #fileID, line: UInt = #line, column: UInt = #column) {
        wrappedValue = Key(fileID: "\(fileID)", line: line, column: column, name: name, element: nil)
    }

    /// A per-element key (one effect per row): `effects.perform(id: $download.scoped(row.id))`.
    ///
    /// Build per-element keys from one declaration. A key named at a call site is keyed by that
    /// call site, so a perform and a cancel written at two sites never match.
    public func scoped(_ element: some Hashable) -> Key {
        Key(
            fileID: wrappedValue.fileID,
            line: wrappedValue.line,
            column: wrappedValue.column,
            name: wrappedValue.name,
            element: AnyHashable(element)
        )
    }
}

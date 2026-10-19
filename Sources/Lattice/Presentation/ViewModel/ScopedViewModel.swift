import IdentifiedCollections
import SwiftUI

#if canImport(CasePaths)
    import CasePaths
#endif

/// A stateless, fine-grained projection of a parent ``ViewModel`` onto a child state and a child
/// action space.
///
/// Create a scope with `viewModel.scope(state:action:)`.
/// Reads go through `Child.ViewState`, so `@Domain` members of the child stay hidden, and they
/// register on the child's observation registrar, so a child view re-renders only when what it
/// read changes. ``sendViewEvent(_:)`` embeds child actions into the parent action and sends them
/// to the parent view model.
///
/// ## Observe members, not the container
///
/// Read **members** through the scope (`model.title`, `model.badge.count`, or
/// ``binding(_:sending:)``) so observation tracks the live getter chain and the view re-renders
/// on in-place mutations. Reading the whole-slice ``viewState`` value registers only the path to
/// the child and will **not** re-render on an in-place leaf mutation — exactly the same
/// distinction as `viewModel.title` (fine-grained) versus `viewModel.viewState` (coarse). Member
/// access at any depth stays fine-grained because each hop invokes a live `@FeatureState`
/// getter; the rule is the chain of getters you actually read, not how deep the slice is.
///
/// A scope reads its child live from the parent on every access. (A captured child value would
/// still be notified, because value copies share their registrar, but would serve stale data.)
///
/// `ScopedViewModel` is a value type that owns no state, effects, or lifecycle, so it is cheap
/// to recreate on every render.
///
/// Create scopes inline in `body` and do not store them (e.g. in `@State` or any long-lived
/// property): a scope strongly retains its parent ``ViewModel``, so storing one beyond the
/// render that created it extends the parent's lifetime and delays the effect cancellation
/// that runs in the parent's `deinit`.
@dynamicMemberLookup
@MainActor
public struct ScopedViewModel<Child: FeatureState, ChildAction> {
    private let _state: @MainActor () -> Child
    private let _send: @MainActor (ChildAction) -> Task<Void, Never>?

    init(
        state: @escaping @MainActor () -> Child,
        send: @escaping @MainActor (ChildAction) -> Task<Void, Never>?
    ) {
        self._state = state
        self._send = send
    }

    /// The whole child projection.
    ///
    /// This is the **coarse** read: like ``ViewModel/viewState`` it re-renders only when the
    /// child is replaced (or, for an enum child, changes case) and **not** on an in-place leaf
    /// mutation. Members read off the value stay fine-grained. To observe leaf changes, read
    /// members through the scope instead (`model.title`), which is the common case.
    public var viewState: Child.ViewState { Child.ViewState(_state()) }

    /// Accesses a member of the child projection with fine-grained observation.
    ///
    /// This is the **fine-grained** read: `model.title` (or deeper, `model.badge.count`) walks
    /// the live `@FeatureState` getter chain and re-renders the view on in-place mutations
    /// of that member. Prefer this over ``viewState`` in views.
    public subscript<V>(dynamicMember keyPath: KeyPath<Child.ViewState, V>) -> V {
        Child.ViewState(_state())[keyPath: keyPath]
    }

    /// Sends a child action, embedding it into the parent action and sending it to the parent
    /// view model.
    ///
    /// To hand off to a child view that takes a `(ChildAction) -> Void` callback, wrap in a
    /// closure (the returned task is discarded):
    ///
    /// ```swift
    /// ChildView(action: { scoped.sendViewEvent($0) })
    /// ```
    ///
    /// For a child declared with a type-erased `(Any) -> Void` callback, bridge at the call
    /// site, where the consumer who chose erasure owns the cast and its mismatch policy:
    ///
    /// ```swift
    /// ErasedChildView(action: { if let a = $0 as? ChildAction { scoped.sendViewEvent(a) } })
    /// ```
    ///
    /// - Parameter action: The child action to embed and dispatch.
    /// - Returns: The task for the effects the dispatched action started, or `nil` when it
    ///   started none.
    @discardableResult
    public func sendViewEvent(_ action: ChildAction) -> Task<Void, Never>? {
        _send(action)
    }

    #if canImport(CasePaths)
        /// Returns a binding whose getter reads the given key path with fine-grained
        /// observation and whose setter sends the new value embedded as a child action.
        ///
        /// - Parameters:
        ///   - keyPath: A key path into the child projection to read.
        ///   - embed: A case key path that wraps the new value into a child action.
        /// - Returns: A two-way binding over the child member.
        public func binding<V>(
            _ keyPath: KeyPath<Child.ViewState, V>,
            sending embed: CaseKeyPath<ChildAction, V>
        ) -> Binding<V> {
            let state = self._state
            let send = self._send
            return Binding(
                get: { Child.ViewState(state())[keyPath: keyPath] },
                set: { newValue in _ = send(embed(newValue)) }
            )
        }
    #endif
}

/// Lets `ForEach(viewModel.scope(state: \.rows, action: \.row))` identify rows.
extension ScopedViewModel: @MainActor Identifiable where Child: Identifiable {
    public var id: Child.ID { _state().id }
}

// MARK: - Scoping

// Each scoping primitive is implemented once, on `ScopedViewModel` over `Child.ViewState`. The
// `ViewModel` overloads below delegate to `rootScope`, a scope over the whole state, so both
// surfaces offer the same overloads with the same behavior. The child is recovered from a
// projection as `P.State`, so `\.badge` infers without annotation.

#if canImport(CasePaths)
    extension ScopedViewModel where ChildAction: CasePathable {
        /// Projects this scope onto a child state and a child action space.
        ///
        /// The child action is embedded into this scope's action with `embed`. This is sugar over
        /// the closure-based `scope(state:action:)` overload.
        ///
        /// - Parameters:
        ///   - keyPath: A key path to a `@FeatureState` child, as projected by `Child.ViewState`.
        ///   - embed: A case key path that embeds the child action into this scope's action.
        /// - Returns: A ``ScopedViewModel`` over the child state and action.
        public func scope<P: ViewStateProjection, GrandchildAction>(
            state keyPath: KeyPath<Child.ViewState, P>,
            action embed: CaseKeyPath<ChildAction, GrandchildAction>
        ) -> ScopedViewModel<P.State, GrandchildAction> {
            scope(state: keyPath, action: { embed($0) })
        }

        /// Projects this scope onto an optional child state, or returns `nil` while the child is
        /// absent.
        ///
        /// Reads are live. If the child is removed while the scope is still held (at most one
        /// transitional render), reads serve the child captured when the scope was created.
        ///
        /// - Parameters:
        ///   - keyPath: A key path to an optional `@FeatureState` child.
        ///   - embed: A case key path that embeds the child action into this scope's action.
        /// - Returns: A scope over the child, or `nil` if the child is absent.
        public func scope<P: ViewStateProjection, GrandchildAction>(
            state keyPath: KeyPath<Child.ViewState, P?>,
            action embed: CaseKeyPath<ChildAction, GrandchildAction>
        ) -> ScopedViewModel<P.State, GrandchildAction>? {
            guard let snapshot = Child.ViewState(_state())[keyPath: keyPath]?._state else { return nil }
            return ScopedViewModel<P.State, GrandchildAction>(
                state: { [self] in Child.ViewState(self._state())[keyPath: keyPath]?._state ?? snapshot },
                send: { [self] in self._send(embed($0)) }
            )
        }

        /// Projects this scope onto every element of a collection of child states.
        ///
        /// Returns one scope per element; the scopes are `Identifiable`, so
        /// `ForEach(model.scope(state: \.rows, action: \.row))` works directly. Each scope
        /// re-finds its element by id on every read (O(n)); an `IdentifiedArray` collection uses
        /// the O(1) overload instead. If the element is removed while the scope is still held,
        /// reads serve the element captured when the scope was created.
        ///
        /// - Parameters:
        ///   - keyPath: A key path to a collection of identifiable `@FeatureState` children.
        ///   - embed: A case key path that embeds an element action, tagged with the element's
        ///     id, into this scope's action.
        /// - Returns: One scope per element, in collection order.
        public func scope<C: RandomAccessCollection, ElementAction>(
            state keyPath: KeyPath<Child.ViewState, ViewStateCollection<C>>,
            action embed: CaseKeyPath<ChildAction, (C.Element.ID, ElementAction)>
        ) -> [ScopedViewModel<C.Element, ElementAction>] where C.Element: FeatureState & Identifiable {
            Child.ViewState(_state())[keyPath: keyPath]._base.map { snapshot in
                let id = snapshot.id
                return ScopedViewModel<C.Element, ElementAction>(
                    state: { [self] in
                        Child.ViewState(self._state())[keyPath: keyPath]._base.first { $0.id == id } ?? snapshot
                    },
                    send: { [self] in self._send(embed((id, $0))) }
                )
            }
        }

        /// Projects this scope onto every element of an `IdentifiedArray` of child states.
        ///
        /// The `IdentifiedArray` specialisation of the collection overload: each scope looks its
        /// element up by id in O(1). Overload ranking prefers it whenever the collection is an
        /// `IdentifiedArray`.
        ///
        /// - Parameters:
        ///   - keyPath: A key path to an `IdentifiedArray` of `@FeatureState` children.
        ///   - embed: A case key path that embeds an element action, tagged with the element's
        ///     id, into this scope's action.
        /// - Returns: One scope per element, in collection order.
        public func scope<ID: Hashable, Element: FeatureState & Identifiable, ElementAction>(
            state keyPath: KeyPath<Child.ViewState, ViewStateCollection<IdentifiedArray<ID, Element>>>,
            action embed: CaseKeyPath<ChildAction, (ID, ElementAction)>
        ) -> [ScopedViewModel<Element, ElementAction>] where Element.ID == ID {
            Child.ViewState(_state())[keyPath: keyPath]._base.map { snapshot in
                let id = snapshot.id
                return ScopedViewModel<Element, ElementAction>(
                    state: { [self] in Child.ViewState(self._state())[keyPath: keyPath]._base[id: id] ?? snapshot },
                    send: { [self] in self._send(embed((id, $0))) }
                )
            }
        }
    }

    extension ScopedViewModel where Child.ViewState: CasePathable, ChildAction: CasePathable {
        /// Projects this scope onto the payload of an enum case of the child, if that case is
        /// currently active.
        ///
        /// Enum scoping goes through the `@CasePathable` mirror `Child.ViewState`, so the case
        /// path names a `@FeatureState` payload projection. This is the primitive form;
        /// ``scope(state:action:fileID:line:)`` is trapping sugar over it for use inside a matched
        /// `switch` case. Reads are live: the returned scope re-extracts the payload on every
        /// access, so in-place payload mutations are observed fine-grained. If the case
        /// deactivates while the scope is still held (at most one transitional render), reads
        /// serve the payload captured at creation.
        ///
        /// Sends are embedded with `embed` and sent to the parent view model. A send can arrive
        /// after the case has deactivated; the interactor should drop actions that no longer
        /// apply to the current state (`Interactors.When` over a case path does).
        ///
        /// - Parameters:
        ///   - casePath: A case key path to a `@FeatureState` payload of the child's mirror enum.
        ///   - embed: A case key path that embeds the payload action into this scope's action.
        /// - Returns: A scope over the case's payload, or `nil` if the case is not active.
        public func scopeIfActive<P: ViewStateProjection, CaseAction>(
            state casePath: CaseKeyPath<Child.ViewState, P>,
            action embed: CaseKeyPath<ChildAction, CaseAction>
        ) -> ScopedViewModel<P.State, CaseAction>? {
            guard let snapshot = Child.ViewState(_state())[case: casePath]?._state else { return nil }
            return ScopedViewModel<P.State, CaseAction>(
                state: { [self] in Child.ViewState(self._state())[case: casePath]?._state ?? snapshot },
                send: { [self] in self._send(embed($0)) }
            )
        }

        /// Projects this scope onto the payload of the currently active enum case of the child,
        /// trapping if the case is not active.
        ///
        /// Call this only inside a `switch` case that just matched the same case:
        ///
        /// ```swift
        /// switch model.viewState {
        /// case .loading:
        ///     LoadingView()
        /// case .loaded:
        ///     LoadedView(model: model.scope(state: \.loaded, action: \.loaded))
        /// }
        /// ```
        ///
        /// Body evaluation is synchronous on the main actor, so within a matched case this cannot
        /// trap. Use ``scopeIfActive(state:action:)`` when the case may legitimately be inactive.
        public func scope<P: ViewStateProjection, CaseAction>(
            state casePath: CaseKeyPath<Child.ViewState, P>,
            action embed: CaseKeyPath<ChildAction, CaseAction>,
            fileID: StaticString = #fileID,
            line: UInt = #line
        ) -> ScopedViewModel<P.State, CaseAction> {
            guard let scoped = scopeIfActive(state: casePath, action: embed) else {
                fatalError(
                    """
                    scope(state:action:) at \(fileID):\(line): scoped into case '\(casePath)' \
                    while it is not the active case. Call this only inside a switch case that \
                    matched the same case, or use scopeIfActive(state:action:).
                    """
                )
            }
            return scoped
        }
    }
#endif

extension ScopedViewModel {
    /// Projects this scope onto a child state and a child action space, mapping child actions
    /// into this scope's actions with a closure.
    ///
    /// This is the general form and has no `CasePathable` requirement; the case-path
    /// `scope(state:action:)` overload is sugar over it.
    ///
    /// - Parameters:
    ///   - keyPath: A key path to a `@FeatureState` child, as projected by `Child.ViewState`.
    ///   - embed: A closure that maps a child action into this scope's action.
    /// - Returns: A ``ScopedViewModel`` over the child state and action.
    public func scope<P: ViewStateProjection, GrandchildAction>(
        state keyPath: KeyPath<Child.ViewState, P>,
        action embed: @escaping @MainActor (GrandchildAction) -> ChildAction
    ) -> ScopedViewModel<P.State, GrandchildAction> {
        ScopedViewModel<P.State, GrandchildAction>(
            state: { [self] in Child.ViewState(self._state())[keyPath: keyPath]._state },
            send: { [self] in self._send(embed($0)) }
        )
    }

    /// Projects this scope onto a read-only child, for child views that display state but send
    /// no actions.
    ///
    /// - Parameter keyPath: A key path to a `@FeatureState` child, as projected by
    ///   `Child.ViewState`.
    /// - Returns: A ``ScopedViewModel`` whose action type is `Never`.
    public func scope<P: ViewStateProjection>(
        state keyPath: KeyPath<Child.ViewState, P>
    ) -> ScopedViewModel<P.State, Never> {
        ScopedViewModel<P.State, Never>(
            state: { [self] in Child.ViewState(self._state())[keyPath: keyPath]._state },
            send: { (_: Never) -> Task<Void, Never>? in }  // `Never` has no values: never called
        )
    }
}

extension ViewModel {
    /// A scope over the whole state, reading it live from this view model. Every `ViewModel`
    /// `scope` overload projects from it.
    private var rootScope: ScopedViewModel<State, Action> {
        ScopedViewModel(
            state: { [self] in self.state },
            send: { [self] in self.sendViewEvent($0) }
        )
    }
}

#if canImport(CasePaths)
    extension ViewModel where Action: CasePathable {
        /// Projects this view model onto a child state and a child action space.
        ///
        /// The child action is embedded into this feature's action with `embed`:
        ///
        /// ```swift
        /// BadgeView(model: viewModel.scope(state: \.badge, action: \.badge))
        /// ```
        ///
        /// - Parameters:
        ///   - keyPath: A key path to a `@FeatureState` child, as projected by `State.ViewState`.
        ///   - embed: A case key path that embeds the child action into this feature's action.
        /// - Returns: A ``ScopedViewModel`` over the child state and action.
        public func scope<P: ViewStateProjection, ChildAction>(
            state keyPath: KeyPath<State.ViewState, P>,
            action embed: CaseKeyPath<Action, ChildAction>
        ) -> ScopedViewModel<P.State, ChildAction> {
            rootScope.scope(state: keyPath, action: embed)
        }

        /// Projects this view model onto an optional child state, or returns `nil` while the
        /// child is absent.
        ///
        /// Reads are live. If the child is removed while the scope is still held (at most one
        /// transitional render), reads serve the child captured when the scope was created.
        ///
        /// - Parameters:
        ///   - keyPath: A key path to an optional `@FeatureState` child.
        ///   - embed: A case key path that embeds the child action into this feature's action.
        /// - Returns: A scope over the child, or `nil` if the child is absent.
        public func scope<P: ViewStateProjection, ChildAction>(
            state keyPath: KeyPath<State.ViewState, P?>,
            action embed: CaseKeyPath<Action, ChildAction>
        ) -> ScopedViewModel<P.State, ChildAction>? {
            rootScope.scope(state: keyPath, action: embed)
        }

        /// Projects this view model onto every element of a collection of child states.
        ///
        /// Returns one `Identifiable` scope per element, ready for `ForEach`:
        ///
        /// ```swift
        /// ForEach(viewModel.scope(state: \.rows, action: \.row)) { row in
        ///     RowView(model: row)
        /// }
        /// ```
        ///
        /// Each scope re-finds its element by id on every read (O(n)); an `IdentifiedArray`
        /// collection uses the O(1) overload instead. If the element is removed while the scope
        /// is still held, reads serve the element captured when the scope was created.
        ///
        /// - Parameters:
        ///   - keyPath: A key path to a collection of identifiable `@FeatureState` children.
        ///   - embed: A case key path that embeds an element action, tagged with the element's
        ///     id, into this feature's action.
        /// - Returns: One scope per element, in collection order.
        public func scope<C: RandomAccessCollection, ChildAction>(
            state keyPath: KeyPath<State.ViewState, ViewStateCollection<C>>,
            action embed: CaseKeyPath<Action, (C.Element.ID, ChildAction)>
        ) -> [ScopedViewModel<C.Element, ChildAction>] where C.Element: FeatureState & Identifiable {
            rootScope.scope(state: keyPath, action: embed)
        }

        /// Projects this view model onto every element of an `IdentifiedArray` of child states.
        ///
        /// The `IdentifiedArray` specialisation of the collection overload: each scope looks its
        /// element up by id in O(1). Overload ranking prefers it whenever the collection is an
        /// `IdentifiedArray`.
        ///
        /// - Parameters:
        ///   - keyPath: A key path to an `IdentifiedArray` of `@FeatureState` children.
        ///   - embed: A case key path that embeds an element action, tagged with the element's
        ///     id, into this feature's action.
        /// - Returns: One scope per element, in collection order.
        public func scope<ID: Hashable, Element: FeatureState & Identifiable, ChildAction>(
            state keyPath: KeyPath<State.ViewState, ViewStateCollection<IdentifiedArray<ID, Element>>>,
            action embed: CaseKeyPath<Action, (ID, ChildAction)>
        ) -> [ScopedViewModel<Element, ChildAction>] where Element.ID == ID {
            rootScope.scope(state: keyPath, action: embed)
        }
    }

    extension ViewModel where State.ViewState: CasePathable, Action: CasePathable {
        /// Enum state: projects the active case's payload, `nil` otherwise.
        ///
        /// Enum scoping goes through the `@CasePathable` mirror `State.ViewState`, so the case
        /// path names a `@FeatureState` payload projection. Reads are live: the returned scope
        /// re-extracts the payload on every access, so in-place payload mutations are observed
        /// fine-grained. If the case deactivates while the scope is still held (at most one
        /// transitional render), reads serve the payload captured at creation.
        ///
        /// Sends are embedded into this feature's action with `embed` and sent to this view
        /// model. A send can arrive after the case has deactivated; the interactor
        /// should drop actions that no longer apply to the current state (`Interactors.When`
        /// over a case path does).
        ///
        /// - Parameters:
        ///   - casePath: A case key path to a `@FeatureState` payload of the state's mirror enum.
        ///   - embed: A case key path that embeds the payload action into this feature's action.
        /// - Returns: A scope over the case's payload, or `nil` if the case is not active.
        public func scopeIfActive<P: ViewStateProjection, ChildAction>(
            state casePath: CaseKeyPath<State.ViewState, P>,
            action embed: CaseKeyPath<Action, ChildAction>
        ) -> ScopedViewModel<P.State, ChildAction>? {
            rootScope.scopeIfActive(state: casePath, action: embed)
        }

        /// Trapping form for use inside a matched `switch viewModel.viewState` case:
        ///
        /// ```swift
        /// switch viewModel.viewState {
        /// case .loading:
        ///     LoadingView()
        /// case .loaded:
        ///     LoadedView(model: viewModel.scope(state: \.loaded, action: \.loaded))
        /// }
        /// ```
        ///
        /// Body evaluation is synchronous on the main actor, so within a matched case this cannot
        /// trap. Use ``scopeIfActive(state:action:)`` when the case may legitimately be inactive.
        public func scope<P: ViewStateProjection, ChildAction>(
            state casePath: CaseKeyPath<State.ViewState, P>,
            action embed: CaseKeyPath<Action, ChildAction>,
            fileID: StaticString = #fileID,
            line: UInt = #line
        ) -> ScopedViewModel<P.State, ChildAction> {
            rootScope.scope(state: casePath, action: embed, fileID: fileID, line: line)
        }
    }
#endif

extension ViewModel {
    /// Closure-mapped child action (no `CasePathable` requirement).
    ///
    /// This is the general form; the case-path `scope(state:action:)` overload is sugar over it.
    /// Reach for it when the parent action is not `@CasePathable`, or when the mapping is not a
    /// plain case embedding.
    ///
    /// - Parameters:
    ///   - keyPath: A key path to a `@FeatureState` child, as projected by `State.ViewState`.
    ///   - embed: A closure that maps a child action into this feature's action.
    /// - Returns: A ``ScopedViewModel`` over the child state and action.
    public func scope<P: ViewStateProjection, ChildAction>(
        state keyPath: KeyPath<State.ViewState, P>,
        action embed: @escaping @MainActor (ChildAction) -> Action
    ) -> ScopedViewModel<P.State, ChildAction> {
        rootScope.scope(state: keyPath, action: embed)
    }

    /// Read-only child, for child views that display state but send no actions.
    ///
    /// - Parameter keyPath: A key path to a `@FeatureState` child, as projected by
    ///   `State.ViewState`.
    /// - Returns: A ``ScopedViewModel`` whose action type is `Never`.
    public func scope<P: ViewStateProjection>(
        state keyPath: KeyPath<State.ViewState, P>
    ) -> ScopedViewModel<P.State, Never> {
        rootScope.scope(state: keyPath)
    }
}

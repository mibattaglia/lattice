import Observation

/// A generic class that binds a SwiftUI view to a feature's state and interactor.
///
/// `ViewModel` connects a ``Feature`` to SwiftUI. Views send user events through
/// ``sendViewEvent(_:)`` and read the state's view-facing projection, `State.ViewState`.
///
/// ## Overview
///
/// `ViewModel` is a thin main-actor shell over the feature's runtime. The data flow is
/// unidirectional:
///
/// 1. The view calls `sendViewEvent(_:)` with a user action
/// 2. The ``Interactor`` mutates the state synchronously and enqueues effects
/// 3. The state is committed; the previous effects of the same action case are cancelled
/// 4. The new effects start in order on the main actor, each running until its first suspension
///    before `sendViewEvent(_:)` returns
/// 5. Effects resume on the main actor after every suspension and deliver their results with
///    ``Effects/modify(_:)``
/// 6. Views re-render from the members they read
///
/// ## Initialization
///
/// Create a view model from the initial state and a `Feature`:
///
/// ```swift
/// let viewModel = ViewModel(
///     initialState: CounterState(),
///     feature: Feature(interactor: CounterInteractor())
/// )
/// ```
///
/// ## Reading State
///
/// Views read through `State.ViewState`, the projection `@FeatureState` generates: `@Domain`
/// members are absent from it, and every member read stays observation-tracked.
///
/// - Member reads (`viewModel.title`, `viewModel.badge.count`) are fine-grained: a view
///   re-renders only when a member it read changes.
/// - ``viewState`` is the coarse read: the value re-renders on wholesale replacement or an enum
///   case change, while members read off it stay fine-grained.
///
/// ## SwiftUI Integration
///
/// Use `@State` to hold the view model:
///
/// ```swift
/// struct CounterView: View {
///     @State var viewModel = ViewModel(
///         initialState: CounterState(),
///         feature: Feature(interactor: CounterInteractor())
///     )
///
///     var body: some View {
///         Text("Count: \(viewModel.count)")
///         Button("Increment") {
///             viewModel.sendViewEvent(.increment)
///         }
///     }
/// }
/// ```
///
/// ## Awaiting Effects
///
/// ``sendViewEvent(_:)`` returns the task for the effects the action started (not for effects
/// those effects start in turn):
///
/// ```swift
/// .refreshable {
///     await viewModel.sendViewEvent(.refresh)?.value
/// }
/// ```
///
/// Deallocating the view model cancels its effects.
@dynamicMemberLookup
@MainActor
public final class ViewModel<F: FeatureProtocol>: Observable {
    public typealias Action = F.Action
    public typealias State = F.State

    private let core: Core<State, Action>

    /// Creates a view model for a concrete feature.
    ///
    /// - Parameters:
    ///   - initialState: The initial state value.
    ///   - feature: The feature bundle containing the interactor and the state equality.
    public init(initialState: State, feature: F) {
        core = Core(
            isolation: MainActor.shared,
            initialState: initialState,
            interactor: feature.interactor,
            areStatesEqual: feature.areStatesEqual
        )
    }

    /// Whole projection. The value itself is coarse: re-renders on wholesale replacement or enum
    /// case change. Members read off it stay fine-grained (the copy shares every registrar), so
    /// `switch viewModel.viewState { case .loaded(let l): Text(l.title) }` re-renders on case
    /// changes and on `title` changes only.
    public var viewState: State.ViewState { State.ViewState(state) }

    /// Member read with fine-grained observation; also registers the root, so struct states never
    /// need `viewState` for observation.
    public subscript<V>(dynamicMember keyPath: KeyPath<State.ViewState, V>) -> V {
        State.ViewState(state)[keyPath: keyPath]
    }

    /// Processes the action synchronously (state, auto-cancel, effect preambles) and returns the
    /// task for the effects it started, or `nil` when it started none.
    ///
    /// Awaiting the task waits for exactly those effects; effects started by actions they send are
    /// not covered. Cancelling it cancels them.
    @discardableResult
    public func sendViewEvent(_ event: Action) -> Task<Void, Never>? {
        core.send(event)
    }

    /// Raw state. Internal: `ScopedViewModel` and bindings live in this module. Registers on the
    /// runtime's registrar, which is what `withObservationTracking` records.
    var state: State { core.state }

    #if swift(<6.4)
        @_optimize(none)
    #endif
    isolated deinit {
        core.invalidate()
    }
}

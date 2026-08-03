import IdentifiedCollections
import Observation

/// A thin, main-actor host that binds a SwiftUI view to a feature's domain logic.
///
/// `ViewModel` owns the feature's runtime core and a per-instance ``FeatureStateRegistrar``
/// side table. Views send user events through ``sendViewEvent(_:)``, and render by reading
/// view-visible members through dynamic member lookup, which routes through the state's
/// generated view projection.
///
/// ## Overview
///
/// The data flow is unidirectional:
///
/// 1. The view calls `sendViewEvent(_:)` with a user action.
/// 2. The ``Interactor`` processes the action synchronously, mutating domain state in place
///    and launching effects via ``Effects/perform(id:_:fileID:filePath:line:column:)``.
/// 3. Every mutation commits through a single funnel: the generated
///    `_commit(old:new:registrar:key:)` diff fires the registrar for exactly the view-visible
///    members whose value or derived output changed.
/// 4. Effects re-enter by mutating state directly (``EffectState/modify(_:fileID:filePath:line:column:)``);
///    each re-entry is its own commit through the same funnel.
/// 5. The view observes the fired members and re-renders.
///
/// ## Ordering guarantee
///
/// For a non-reentrant `sendViewEvent`: the update phase runs, every synchronous mutation is
/// committed through the funnel (transition detection, then the projection diff firing the
/// registrar for changed members), effect tasks launch in-domain (they cannot preempt the
/// update; their first suspension point is after the send returns), and then `sendViewEvent`
/// returns the ``EventTask``. Effects' later `modify` calls commit through the same funnel
/// one at a time, each firing exactly the projection keys that commit changed.
///
/// A `sendViewEvent` re-entered synchronously from an observer notified mid-commit executes
/// as a plain synchronous recursion — its own full update, commit, and effect launch,
/// returning its own ``EventTask``.
///
/// ## SwiftUI Integration
///
/// ```swift
/// struct CounterView: View {
///     @State var viewModel = ViewModel(
///         initialState: CounterState(),
///         interactor: CounterInteractor()
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
/// Use ``EventTask/finish()`` to await the effects a send launched:
///
/// ```swift
/// .refreshable {
///     await viewModel.sendViewEvent(.refresh).finish()
/// }
/// ```
///
/// ## Teardown
///
/// `ViewModel` owns no teardown hook: it is the unique strong owner of the core (effects
/// capture the core weakly; ``EventTask`` holds only effect task handles), so releasing the
/// last reference tears the core down, which cancels every in-flight effect. A late
/// `effectState.modify` after teardown throws `CancellationError`.
@MainActor
@dynamicMemberLookup
public final class ViewModel<State: FeatureStateProtocol, Action>: Observable {
    private let core: LatticeCore<State, Action>
    let registrar = FeatureStateRegistrar()

    /// Creates a ViewModel hosting the given interactor over the given initial state.
    ///
    /// - Parameters:
    ///   - initialState: The initial domain state value.
    ///   - interactor: The feature's interactor tree.
    public init(initialState: State, interactor: some Interactor<State, Action>) {
        let core = LatticeCore<State, Action>(
            initialState: initialState,
            isolation: MainActor.shared
        )
        self.core = core

        // The root effects handle: combinators derive child handles (extending the
        // GraphPath and lens chain) from it during `interact`.
        let rootEffects = _makeEffectsHandles(core: core, lens: .identity, path: GraphPath())
        core.mount(
            interact: { state, action in
                interactor.interact(state: &state, action: action, effects: rootEffects)
            },
            onCommit: { [registrar] old, new in
                registrar.commit {
                    State._commit(old: old, new: new, registrar: registrar, key: ProjectionKey())
                }
            }
        )
    }

    /// Creates a ViewModel from a ``Feature`` bundle.
    ///
    /// - Parameters:
    ///   - initialState: The initial domain state value.
    ///   - feature: The feature bundle pairing the state type with an erased interactor.
    public convenience init<F: FeatureProtocol>(initialState: State, feature: F)
    where F.State == State, F.Action == Action {
        self.init(initialState: initialState, interactor: feature.interactor)
    }

    /// The view read surface over the core's committed state.
    var projection: FeatureProjection<State> {
        FeatureProjection(
            read: { [core] in core.currentState },
            registrar: registrar,
            key: ProjectionKey()
        )
    }

    /// Coarse whole-state read for case bindings: registers the root observation slot
    /// (poked whenever a commit changed anything visible) and reads committed state.
    var _observedState: State {
        registrar.access(ProjectionKey())
        return core.currentState
    }

    // Root dynamic-member lookups mirror FeatureProjection's overload set
    // (leaf / child / optional child / collection) and delegate to it.

    @_disfavoredOverload
    public subscript<Value: Equatable>(
        dynamicMember member: KeyPath<State._ViewMembers, Value>
    ) -> Value {
        projection[dynamicMember: member]
    }

    public subscript<Child: FeatureStateProtocol>(
        dynamicMember member: KeyPath<State._ViewMembers, Child>
    ) -> FeatureProjection<Child> {
        projection[dynamicMember: member]
    }

    public subscript<Child: FeatureStateProtocol>(
        dynamicMember member: KeyPath<State._ViewMembers, Child?>
    ) -> FeatureProjection<Child>? {
        projection[dynamicMember: member]
    }

    public subscript<Element>(
        dynamicMember member: KeyPath<State._ViewMembers, IdentifiedArrayOf<Element>>
    ) -> CollectionProjection<Element>
    where Element: FeatureStateProtocol & Identifiable & Equatable {
        projection[dynamicMember: member]
    }

    /// Sends an action to the interactor and returns a handle over the effects the update
    /// launched directly.
    ///
    /// The update phase — and every mutation commit it produces — completes synchronously
    /// before this method returns.
    ///
    /// - Parameter event: The action to send.
    /// - Returns: An ``EventTask`` whose `finish()` awaits the effects this send launched
    ///   directly, and whose `cancel()` cancels them.
    @discardableResult
    public func sendViewEvent(_ event: Action) -> EventTask {
        EventTask(rawValue: (try? core.send(event)) ?? nil)
    }
}

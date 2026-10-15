/// A feature running on its own serial executor, off the main actor: for non-view-bound features
/// and for parallel tests.
///
/// `ActorModel` is a thin actor shell over the feature's runtime, as ``ViewModel`` is on the main
/// actor. The model's executor is the runtime's isolation: ``send(_:)`` processes an action
/// synchronously on it, and every effect starts on it and resumes on it after each suspension,
/// serialized with the model's methods.
///
/// ```swift
/// let model = await ActorModel(
///     initialState: CounterState(),
///     feature: Feature(interactor: CounterInteractor(counterClient: client))
/// )
/// await model.send(.task)?.value
/// let count = await model.state.count  // reading from outside needs `CounterState: Sendable`
/// ```
///
/// The interactor must not be main-actor-isolated: a main-actor interactor cannot be sent to the
/// model. Such features use ``ViewModel``. `ActorModel` requires iOS 26, macOS 26 or watchOS 26.
///
/// Deallocating the model cancels its effects.
@available(iOS 26, macOS 26, watchOS 26, *)
public actor ActorModel<F: FeatureProtocol> {
    public typealias Action = F.Action
    public typealias State = F.State

    private let isolation: DefaultIsolation
    private let core: Core<State, Action>

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        isolation.unownedExecutor
    }

    /// Creates a model for a feature, on a serial executor of its own.
    ///
    /// - Parameters:
    ///   - initialState: The initial state value.
    ///   - feature: The feature bundle containing the interactor and the state equality.
    public init(initialState: State, feature: F) async {
        let isolation = DefaultIsolation()
        self.isolation = isolation
        core = Core(
            isolation: isolation,
            initialState: initialState,
            interactor: feature.interactor,
            areStatesEqual: feature.areStatesEqual
        )
    }

    /// The committed state. Reading it from another isolation (`await model.state`) needs
    /// `State: Sendable`, as for any actor-isolated property.
    public var state: State {
        core.state
    }

    /// Processes the action synchronously (state, auto-cancel, effect preambles) and returns the
    /// task for the effects it started, or `nil` when it started none.
    ///
    /// Awaiting the task waits for exactly those effects; effects started by actions they send are
    /// not covered. Cancelling it cancels them.
    @discardableResult
    public func send(_ action: Action) -> Task<Void, Never>? {
        core.send(action)
    }

    #if swift(<6.4)
        @_optimize(none)
    #endif
    isolated deinit {
        core.invalidate()
    }
}

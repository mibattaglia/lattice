import IssueReporting
import Observation

/// Where `Core` tracks a started effect.
enum EffectLocation: Hashable {
    /// An anonymous effect, keyed by the enum-tag path of the handle that performed it (root
    /// action tag, then one tag per `When` hop); cancelled when that path is handled again.
    case anonymous([Int])
    /// An `@EffectID` effect, keyed by the `When` scope path of the handle and the declared key;
    /// replaced by the next effect of the same key and cancelled only through `cancel(_:)`.
    case identified([AnyHashable], EffectID.Key)
}

/// The feature runtime: state, interactor, effect queue and effect bookkeeping.
///
/// Nonisolated, non-Sendable and lock-free: it is only ever touched on `isolation`, which the shell
/// binds at construction and which effect start asserts through `assumeIsolated`. The bindings:
///
/// - `ViewModel` → `MainActor.shared`
/// - `ActorModel` → its own `DefaultIsolation`
/// - `TestModel` → its own `DefaultIsolation`, through `TestHost`
/// - `TestViewModel` → `MainActor.shared`, through `TestHost`
final class Core<State: FeatureState, Action>: Observable {
    private struct PerformContext {
        /// Every tag path reached while routing the action (root, then each `When` hop): the
        /// auto-cancel targets of this send.
        var visitedPaths: [[Int]]
    }

    private struct QueuedEffect {
        let location: EffectLocation
        /// `nil` for a queued `cancel(_:)`, which runs in order in the start phase.
        let operation: EffectOperation?
    }

    private struct TrackedEffect {
        let token: Int
        /// `nil` while the effect runs its synchronous preamble, before `Task.immediate` returns.
        var task: Task<Void, Never>?
        /// Cancelled by auto-cancel, `cancel(_:)` or replacement, and still unwinding. Kept until it
        /// finishes so `inFlightTasks` covers it; `isRunning` ignores it.
        var isCancelled = false
    }

    let isolation: any Actor
    private let interactor: AnyInteractor<State, Action>
    private let areStatesEqual: ((State, State) -> Bool)?
    private let registrar = ObservationRegistrar()
    private var _state: State
    /// Filled by `perform`/`cancel` during `interact`, drained by `send`.
    private var queued: [QueuedEffect] = []
    /// Started effects that have not finished.
    private var tasks: [EffectLocation: [TrackedEffect]] = [:]
    private var nextToken = 0
    /// Non-nil only while `interact` runs.
    private var performContext: PerformContext?
    private(set) var isRoutingAction = false
    private(set) var isModifying = false
    private(set) var isInvalidated = false

    /// Test hooks (`TestHost`); `nil` in production shells. The action is `nil` for a modification
    /// made by an effect.
    var didCommit: ((Action?, State) -> Void)?
    var effectsDidChange: (() -> Void)?

    init(
        isolation: any Actor,
        initialState: State,
        interactor: AnyInteractor<State, Action>,
        areStatesEqual: ((State, State) -> Bool)?
    ) {
        self.isolation = isolation
        self._state = initialState
        self.interactor = interactor
        self.areStatesEqual = areStatesEqual
    }

    /// The committed state; registers an observation access on the core's registrar.
    var state: State {
        registrar.access(self, keyPath: \.state)
        return _state
    }

    /// The committed state without registering an observation access (`Effects`, `TestHost`).
    var committedState: State { _state }

    /// Every started effect that has not finished, including cancelled ones still unwinding.
    var inFlightTasks: [Task<Void, Never>] {
        tasks.values.joined().compactMap(\.task)
    }

    /// Handles `action`: runs the interactor on a working copy, commits it, auto-cancels the
    /// previous anonymous effects of every path the action visited, then starts the effects the
    /// interactor performed, in order, each running its synchronous preamble before this returns.
    ///
    /// - Returns: The task awaiting exactly the effects this send started, or `nil` for none.
    @discardableResult
    func send(_ action: Action) -> Task<Void, Never>? {
        guard !isInvalidated else {
            reportIssue("Can't send \(action) to an invalidated model")
            return nil
        }
        guard !isRoutingAction else {
            reportIssue(
                "Can't send another action before handling this one; use effects.perform { try effects.send(action) }"
            )
            return nil
        }
        guard !isModifying else {
            reportIssue("Can't send \(action) inside 'modify'; dropped")
            return nil
        }
        let rootPath = [enumTag(action)]
        isRoutingAction = true
        performContext = PerformContext(visitedPaths: [rootPath])
        // A working copy: `interact` never holds an `inout` access to `_state`, so a synchronous
        // read of the committed state during `interact` (an observer, `effects.state`) cannot trap.
        var working = _state
        interactor.interact(state: &working, action: action, effects: Effects(core: self, path: rootPath))
        let visitedPaths = performContext?.visitedPaths ?? []
        performContext = nil
        commit(working)
        for path in visitedPaths {
            cancelTasks(at: .anonymous(path))
        }
        isRoutingAction = false
        didCommit?(action, _state)
        return startQueued().all
    }

    /// A state change from an effect. Same working copy and commit rules as `send`; no perform
    /// context (so `perform` inside `body` is reported and dropped), no auto-cancel, no task.
    func modify(_ body: (inout State) -> Void) {
        guard !isRoutingAction else {
            reportIssue("Can't modify state from effects during interact; mutate the 'state' argument instead")
            return
        }
        guard !isModifying else {
            reportIssue("Can't modify state inside another 'modify'; dropped")
            return
        }
        isModifying = true
        defer { isModifying = false }
        var working = _state
        body(&working)
        commit(working)
        didCommit?(nil, _state)
    }

    /// Cancels every effect and drops the queue. Later `effects.send`/`effects.modify` throw.
    func invalidate() {
        isInvalidated = true
        for tracked in tasks.values.joined() {
            tracked.task?.cancel()
        }
        tasks.removeAll()
        queued.removeAll()
    }

    func enqueue(path: [Int], scopePath: [AnyHashable], id: EffectID.Key?, _ operation: @escaping EffectOperation) {
        guard performContext != nil else {
            reportIssue(
                isModifying
                    ? "Can't perform an effect inside 'modify'; dropped"
                    : "'effects.perform' must be called during interact; dropped"
            )
            return
        }
        let location: EffectLocation = id.map { .identified(scopePath, $0) } ?? .anonymous(path)
        queued.append(QueuedEffect(location: location, operation: operation))
    }

    /// During `interact`: queued, so it runs in order with the effects performed around it. From an
    /// effect: immediate, because nothing would drain the queue before the next send.
    func cancel(scopePath: [AnyHashable], id: EffectID.Key) {
        let location = EffectLocation.identified(scopePath, id)
        if performContext != nil {
            queued.append(QueuedEffect(location: location, operation: nil))
        } else {
            cancelTasks(at: location)
        }
    }

    func isRunning(scopePath: [AnyHashable], id: EffectID.Key) -> Bool {
        tasks[.identified(scopePath, id)]?.contains { !$0.isCancelled } ?? false
    }

    /// Called by `When` when it routes into a child: the child path becomes an auto-cancel target.
    func visit(path: [Int]) {
        performContext?.visitedPaths.append(path)
    }

    /// The interactor (or the effect's `modify` body) mutated a working copy whose `@FeatureState`
    /// registrars are shared with `_state`, so per-member notifications already fired, and an
    /// observer that re-read the model synchronously saw the previous committed value. Only a
    /// wholesale replacement (a new root `_$id`) fires the coarse `\.state` key path.
    private func commit(_ newState: State) {
        let isReplacement = newState._$id != _state._$id
        if isReplacement, let areStatesEqual, areStatesEqual(_state, newState) {
            // Content-equal wholesale replacement: keep the current value so its registrar tree —
            // and every observer registered on it — survives. Nothing changed for the view.
            return
        }
        _state = newState
        if isReplacement {
            registrar.withMutation(of: self, keyPath: \.state) {}
        }
    }

    /// The one place that vouches for safety. Task creation is a `for` loop written directly in the
    /// `assumeIsolated` body: inside a nested closure (`map`, `forEach`, a helper) the task closure
    /// would inherit that closure's nonisolated context, start synchronously and then resume on the
    /// global executor after its first suspension, with no diagnostic.
    private func startQueued() -> [Task<Void, Never>] {
        let effects = queued  // snapshot: a nested send from a preamble must not see these
        queued.removeAll()
        var started: [Task<Void, Never>] = []
        for effect in effects {
            guard !isInvalidated else { break }
            guard let queuedOperation = effect.operation else {
                cancelTasks(at: effect.location)  // a queued `cancel(_:)`: runs in order
                continue
            }
            let location = effect.location
            if case .identified = location {
                cancelTasks(at: location)  // replace per key
            }
            let token = nextToken
            nextToken += 1
            // Registered before it starts, so `isRunning` holds in its own preamble; the handle is
            // attached once `Task.immediate` returns.
            tasks[location, default: []].append(TrackedEffect(token: token))
            // NB: `operation` is non-Sendable but only ever runs on `isolation`, which is the current
            //     isolation (`assumeIsolated` traps otherwise). The compiler cannot relate the dynamic
            //     `any Actor` to the `@isolated(any)` task closure. The same holds for `didFinish`,
            //     which reaches this core weakly.
            nonisolated(unsafe) let operation = queuedOperation
            nonisolated(unsafe) let didFinish = { [weak self] in self?.taskDidFinish(token, at: location) }
            let task = isolation.assumeIsolated { _ in
                Task.immediateIfAvailable {  // starts now, here; resumes here after every await
                    do {
                        try await operation()
                    } catch is CancellationError {
                    } catch _ where Task.isCancelled {
                        // Cancellation can surface as another error (`URLError(.cancelled)`, a
                        // dependency's own): a cancelled effect's throw is not reported either.
                    } catch {
                        reportIssue("Effect threw: \(error)")
                    }
                    didFinish()  // on `isolation`: prune + test host signal
                }
            }
            attach(task, token: token, at: location)
            started.append(task)
        }
        effectsDidChange?()
        return started
    }

    private func attach(_ task: Task<Void, Never>, token: Int, at location: EffectLocation) {
        guard let index = tasks[location]?.firstIndex(where: { $0.token == token }) else {
            // It finished inside its preamble, or `invalidate()` ran while it started.
            if isInvalidated { task.cancel() }
            return
        }
        tasks[location]?[index].task = task
        if tasks[location]?[index].isCancelled == true {
            task.cancel()  // cancelled or replaced while it ran its preamble
        }
    }

    private func taskDidFinish(_ token: Int, at location: EffectLocation) {
        guard let index = tasks[location]?.firstIndex(where: { $0.token == token }) else { return }
        tasks[location]?.remove(at: index)
        if tasks[location]?.isEmpty == true {
            tasks[location] = nil
        }
        effectsDidChange?()
    }

    private func cancelTasks(at location: EffectLocation) {
        guard var entries = tasks[location] else { return }
        for index in entries.indices where !entries[index].isCancelled {
            entries[index].isCancelled = true
            entries[index].task?.cancel()
        }
        tasks[location] = entries
    }
}

/// `enqueue`, `cancel`, `isRunning`, `visit` and `isRoutingAction` already have the protocol's
/// shapes; the handle reaches them through `any EffectRuntime`, so it needs no closures for them.
extension Core: EffectRuntime {}

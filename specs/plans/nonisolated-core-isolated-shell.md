# Nonisolated Core, Isolated Shell

Status: ✅ Complete — breaking change (next major). Supersedes the former
`view-model-event-loop-and-emission-handling.md` (replaced by
[effects-and-isolation.md](../effects-and-isolation.md)), the `Emission` sections of
[interactors.md](../interactors.md), and the buffering/`TestEventTask` sections of
[testing-infrastructure.md](../testing-infrastructure.md). Builds on
[unified-feature-state.md](unified-feature-state.md) (one `@FeatureState` per feature; unchanged here).
Deviations found during implementation are in [§12](#12-implementation-notes).

Every contract in this document was compiled and exercised against Swift 6.4 (Xcode 27, Swift 6
language mode, macOS 14 / iOS 17 deployment floors) in standalone spikes before being written down;
see [§11](#11-references). The pattern is Point-Free's "nonisolated core, isolated shell"
(TCA 2 / `ComposableArchitecture2`, Point-Free videos #382–#383).

## 1. Summary

A feature's runtime is a nonisolated, non-Sendable `Core`: state, interactor, effect queue and
effect bookkeeping, with no locks. A thin isolated shell hosts it — `ViewModel` on the main actor,
`ActorModel` and `TestModel` on a private actor each — and every effect task inherits the shell's
isolation, so after any suspension an effect resumes on the shell. Interactors enqueue effects
imperatively through an `Effects` handle instead of returning an `Emission`, and an effect delivers
its result by mutating state directly — there is no response-action ping-pong. Nothing in the
feature layer is required to be `Sendable`.

| Decision | Outcome |
|---|---|
| Effects | Imperative: `interact(state:action:effects:)`; `effects.perform { … }` enqueues a task. From a task, `effects.state` reads the committed state and `effects.modify { $0.x = … }` commits a change. `Emission`, `.none/.action/.perform/.observe/.merge/.append`, `Emission.debounce`, `Debouncer` are removed. |
| Results | Delivered by `effects.modify`, never by a response action. `effects.send(_:)` remains for the three things a mutation cannot do: start new effects (`perform` is legal only during `interact`), run interactor logic (parent/sibling reaction, `When` routing), and auto-cancel by action case. |
| Start order | Lazy: every `perform` of one `send` is only enqueued; after `interact` returns, the previous effects of the same action case are cancelled and the new ones start in order via `Task.immediate`, each running its synchronous preamble before `send` returns. |
| Reentrancy | `effects.send` and `effects.modify` during `interact` report an issue and are dropped; so are `send`/`modify`/`perform` inside a `modify` body. A send from an effect is processed synchronously, depth-first. The buffered action queue (`isSending`, `BufferedAction`) is removed. |
| Auto-cancel | Re-handling an action case cancels that case's previous anonymous effects (keyed by the enum-tag *path*: root tag, then one tag per `When` hop). `effects.perform(id:)` with an `@EffectID` key opts out and gives explicit `effects.cancel(_:)` / `effects.isRunning(_:)`. |
| `send` result | `Task<Void, Never>?` awaiting exactly the effects started by that send (not transitively). `EventTask`, `TestEventTask`, `RootScopeTasks`, the 1 ms quiescence poll are removed. |
| Isolation | `Core` stores `isolation: any Actor`. Effects start inside `isolation.assumeIsolated { Task.immediateIfAvailable { … } }`; pre-OS-26 main-actor shells use `Task.startOnMainActor`. Actor shells require OS 26. |
| Sendable | No `Sendable` constraints on `State`, `Action`, interactors, `Feature`, effect closures. `UncheckedSendableInteractor`, `eraseToAnyInteractorUnchecked`, every `@unchecked Sendable` operator, `EffectTaskRegistry`, `EffectCancellationRegistry` and both locks are removed. |
| Shells | `ViewModel` (`@MainActor`, SwiftUI), `ActorModel` (actor, OS 26+), `TestModel` (actor, OS 26+, primary test shell), `TestViewModel` (`@MainActor`, for main-actor-isolated interactors). All four forward to one `Core`; the two test shells share one `TestHost`. |
| Teardown | `isolated deinit` on every shell calls `core.invalidate()`: cancels effects; later `effects.send`/`effects.modify` throw `CancellationError`. |
| Toolchain | `NonisolatedNonsendingByDefault` enabled on the `Lattice` target (not on tests, which stand in for consumer modules). |

## 2. Architecture

```text
ViewModel<F> (@MainActor)        ActorModel<F> (actor, 26+)        TestModel<F> (actor, 26+) / TestViewModel<F> (@MainActor)
  private let core                 private let core                  private let host: TestHost  →  host.core
  Core(…, isolation: MainActor.shared)   Core(…, isolation: DefaultIsolation())   (unownedExecutor forwards to it)
  viewState / members → core.state  state → core.state                state, send/receive/finish via host
  sendViewEvent(a) → core.send(a)   send(a) → core.send(a)
  isolated deinit → core.invalidate()

Core<State, Action>  — nonisolated, non-Sendable, Observable; touched only on `isolation`
  send(a)
    guard !isInvalidated, !isRoutingAction                 else reportIssue, return nil
    performContext = [tag(a)]                              `perform` legal from here …
    var working = _state
    interactor.interact(&working, a, Effects(core: self, path: [tag(a)]))
    performContext = nil                                   … to here
    commit(working)                                        unified-feature-state §5.2 rules, unchanged
    cancelTasks(at: every path visited)                    auto-cancel previous effects of this case (and of each When hop)
    didCommit?(a, state)                                   TestHost records the transition
    return startQueued().all                               assumeIsolated { for op in ops { Task.immediateIfAvailable { … } } }

effect task (one per `perform`), on `isolation`
  preamble runs now, before `send` returns
  let model = try await dependency.fetch()                 suspends; resumes ON `isolation`
  try effects.modify { $0.model = model }  → core.modify     working copy → commit (same rules) → didCommit(nil, state)
  try effects.send(.next)  → core.send(.next)               only to start effects / run interactor logic / auto-cancel
  completion → core.taskDidFinish(token)                   pruned from `tasks`; TestHost signalled
```

The interactor stays a value type mutating a working copy whose `@FeatureState` registrars are
shared with the committed value, so per-member observation fires during `interact` and a
synchronous observer that re-reads the model sees the previous committed state (no exclusivity
trap). What changes is the shape of asynchrony: effects are no longer values the shell interprets
off-isolation and funnels back through `MainActor.run`; they are tasks that live on the shell's
isolation from their first instruction to their last.

## 3. Runtime contracts

New files: `Sources/Lattice/Domain/Effects.swift` (public), `Sources/Lattice/Internal/Core.swift`,
`Sources/Lattice/Internal/Runtime/{EnumMetadata,RuntimeMetadata}.swift` and
`Sources/Lattice/Internal/Concurrency/{Task+Immediate,StartOnMainActor}.swift` (the last four are
copied from TCA 2 `Internal/`; `EnumMetadata` drops its CasePaths name cache and needs no C shim).

### 3.1 `Effects`

```swift
import IssueReporting

/// An effect operation. Starts on the owning model's isolation and resumes there after every
/// suspension; it is `nonisolated(nonsending)`, so it never hops to the global executor.
public typealias EffectOperation = nonisolated(nonsending) () async throws -> Void

/// The interactor's handle for asynchronous behaviour. A value type over the feature's `Core`;
/// not `Sendable`, and never needs to be: it only runs on the model's isolation.
///
/// `perform` is legal only while `interact` runs. `state`, `modify` and `send` are legal only from
/// an effect. Both rules are reported through `reportIssue`; `perform` is also rejected at compile
/// time inside async contexts.
public struct Effects<State, Action> {
    /// The committed state. Read from effects; during `interact` it is the pre-action value and the
    /// read is reported (use the `inout` argument instead). After the model is gone, or a case-scoped
    /// child is no longer active, it is the last known value and the read is reported. Get-only:
    /// changes go through `modify`.
    public var state: State { get }

    /// Enqueues an effect. It starts after `interact` returns, in `perform` order, runs its
    /// synchronous preamble before `send` returns and resumes on the model's isolation after every
    /// suspension. Without an `id`, the effect is auto-cancelled the next time this action case is
    /// handled; with an `id` (§3.2), it replaces the previous effect of that key and is cancelled
    /// only through `cancel(_:)`.
    @available(*, noasync)
    public func perform(id: EffectID.Key? = nil, _ operation: @escaping EffectOperation)

    /// Commits a state change from an effect: one commit, one observation pass, one test entry,
    /// however many members `body` touches. This is how an effect delivers its result. Throws only if
    /// the model has been invalidated (deinit); a cancelled effect's change is still committed. During
    /// `interact`, inside another `modify`, or after a case-scoped child's case went away, the change
    /// is reported and dropped. `perform`/`send` inside `body` are reported and dropped.
    public func modify(_ body: (inout State) -> Void) throws(CancellationError)

    /// Sends an action back into the feature from an effect, for what a mutation cannot do: start
    /// new effects, run interactor logic, or auto-cancel by action case. Processed synchronously,
    /// depth-first, and returns the task for the effects that action started. Throws only if the
    /// model has been invalidated; a cancelled effect's send is still delivered.
    @discardableResult
    public func send(_ action: Action) throws(CancellationError) -> Task<Void, Never>?
}
```

Internals (all closures, so `When` and `Debounce` derive child handles without a backend protocol):

```swift
public struct Effects<State, Action> {
    let readState: () -> State?                          // nil: core gone / scoped case inactive
    let isRoutingAction: () -> Bool
    let path: [Int]                                      // enum-tag path of this handle (anonymous effects)
    let scopePath: [AnyHashable]                         // one entry per `When` hop (identified effects)
    let enqueue: ([Int], [AnyHashable], EffectID.Key?, @escaping EffectOperation) -> Void
    let enqueueCancel: ([AnyHashable], EffectID.Key) -> Void
    let isRunningKey: ([AnyHashable], EffectID.Key) -> Bool
    let visit: ([Int]) -> Void                           // registers a child path as an auto-cancel target
    let sendAction: (Action) throws(CancellationError) -> Task<Void, Never>?
    let modifyState: ((inout State) -> Void) throws(CancellationError) -> Void
    let lastKnown: LastKnown<State>                      // final class box, updated on each successful read

    init(core: Core<State, Action>, path: [Int]) {
        readState = { [weak core] in core?.committedState }     // untracked read; `state` registers observation
        isRoutingAction = { [weak core] in core?.isRoutingAction ?? false }
        self.path = path
        enqueue = { [weak core] path, id, op in core?.enqueue(path: path, id: id, op) }
        visit = { [weak core] path in core?.visit(path: path) }
        sendAction = { [weak core] action throws(CancellationError) in
            guard let core, !core.isInvalidated else {
                if !Task.isCancelled { reportIssue("Effect sent \(action) after the model was invalidated") }
                throw CancellationError()
            }
            return core.send(action)
        }
        modifyState = { [weak core] body throws(CancellationError) in
            guard let core, !core.isInvalidated else {
                if !Task.isCancelled { reportIssue("Effect modified state after the model was invalidated") }
                throw CancellationError()
            }
            core.modify(body)                                // reports + drops during interact / inside modify
        }
        lastKnown = LastKnown(core.committedState)
    }

    public var state: State {
        if isRoutingAction() {
            reportIssue("Read 'effects.state' during interact; use the 'state' argument instead")
        }
        guard let state = readState() else {
            reportIssue("Read 'effects.state' after the model was invalidated or the scoped state went away")
            return lastKnown.value
        }
        lastKnown.value = state
        return state
    }

    public func modify(_ body: (inout State) -> Void) throws(CancellationError) {
        try modifyState(body)
    }

    /// Scoping (`When`). `extract` returning `nil` means the child is no longer active: its effects'
    /// sends and modifications are reported and dropped. Key-path scoping passes a non-optional
    /// `extract`. `embedState` writes the child back into the parent (key path assignment or case
    /// re-embedding); a child `modify` is one parent commit, so nested `When`s chain upward.
    /// `scopeEntry` (the `When`'s key path or case key path) extends `scopePath` for identified effects.
    func scope<ChildState, ChildAction>(
        extract: @escaping (State) -> ChildState?,
        embed: @escaping (ChildAction) -> Action,
        embedState: @escaping (inout State, ChildState) -> Void,
        childTag: Int,
        scopeEntry: AnyHashable
    ) -> Effects<ChildState, ChildAction> {
        let childPath = path + [childTag]
        visit(childPath)
        // path: childPath; scopePath: scopePath + [scopeEntry]
        // readState:   parent.readState().flatMap(extract)
        // sendAction:  reportIssue + nil   when !isRoutingAction() && extract(parentState) == nil, else parent.sendAction(embed(child))
        // modifyState: reportIssue + drop  when !isRoutingAction() && extract(parentState) == nil, else
        //              parent.modifyState { p in guard var c = extract(p) else { return }; body(&c); embedState(&p, c) }
    }

    /// Operation transform (`Debounce`): every enqueued operation is wrapped.
    func transformingOperations(_ transform: @escaping (@escaping EffectOperation) -> EffectOperation) -> Effects
}
```

### 3.2 `EffectID`

An effect that must outlive re-handling of its action case, or be cancelled from another case, is
identified by a **key** the interactor declares. The key is a value; the task it names lives in
`Core`. Nothing is stored in state, so state's observation, equality and codability are untouched,
and the identity survives `body` being re-evaluated (every child interactor built inside `body` is
a new value on each `interact`, so an identity held *by* the interactor instance would be lost).

```swift
/// Declares an effect identity on an interactor. The key is the declaration site, so every
/// instance of the declaring type — including the fresh instances `body` builds on each action —
/// names the same effect. Two declarations never collide (`#column` is part of the key).
@propertyWrapper
public struct EffectID {
    public struct Key: Hashable, CustomStringConvertible {
        let fileID: String, line: UInt, column: UInt, name: String?, element: AnyHashable?
    }
    public let wrappedValue: Key
    public var projectedValue: EffectID { self }
    public init(_ name: String? = nil, fileID: StaticString = #fileID, line: UInt = #line, column: UInt = #column)
    /// A per-element key (one effect per row): `effects.perform(id: $download.scoped(row.id))`.
    public func scoped(_ element: some Hashable) -> Key
}

@Interactor<SearchState, SearchAction>
struct SearchInteractor {
    @EffectID var search
    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .queryChanged(let q):
                state.query = q
                effects.perform(id: search) { … }        // replaces the previous `search` effect, from any case
            case .cancelTapped:
                effects.cancel(search)                      // one line; enqueued, runs in the start phase
                state.isSearching = false
            }
        }
    }
}
```

`Effects` gains the key-based surface (`perform(id:)` is this overload; there is no reference-type
id):

```swift
extension Effects {
    @available(*, noasync)
    public func perform(id: EffectID.Key, _ operation: @escaping EffectOperation)   // replace semantics per key
    /// During `interact`: enqueued and executed in order in the start phase, before the effects
    /// queued after it start. From an effect: immediate.
    public func cancel(_ id: EffectID.Key)
    /// Synchronous. `true` from the effect's start until its operation returns, is replaced or is
    /// cancelled. A cancel queued in the same `interact` is not reflected until the start phase.
    public func isRunning(_ id: EffectID.Key) -> Bool
}
```

The registry location is `.identified(scopePath, key)`, where `scopePath` has one entry per `When`
hop (the key path or case key path the `When` was built with). The scope is what keeps
`When(state: \.a) { Child() }` and `When(state: \.b) { Child() }` from cancelling each other's
`search`; it is independent of the action case, so `.cancelTapped` finds the task `.queryChanged`
started. When Lattice grows an interactor graph, `scopePath` becomes the graph path and the registry
is unchanged.

"Is this effect running?" is not observable from the registry. A view that needs it reads explicit
state (`state.isSearching`) that the interactor sets and the effect clears — in a `defer`, because
a cancelled effect never reaches the statements after its suspension point.

### 3.3 `Core`

```swift
import IssueReporting
import Observation

enum EffectLocation: Hashable {
    case anonymous([Int])                       // enum-tag path; auto-cancelled on re-handling of the path
    case identified([AnyHashable], EffectID.Key) // `When` scope path + declared key; replaced per key, cancelled explicitly
}

/// The feature runtime. Nonisolated and non-Sendable: it is only ever touched on `isolation`,
/// which the shell guarantees and `send` asserts. No locks.
final class Core<State: FeatureState, Action>: Observable {
    let isolation: any Actor
    private let interactor: AnyInteractor<State, Action>
    private let areStatesEqual: ((State, State) -> Bool)?
    private let registrar = ObservationRegistrar()
    private var _state: State
    private var queued: [QueuedEffect] = []                    // filled by `perform`/`cancel`, drained by `send`
    private var tasks: [EffectLocation: [TrackedEffect]] = [:] // started, not yet finished
    private var performContext: PerformContext?                // non-nil only while `interact` runs
    private(set) var isRoutingAction = false
    private(set) var isModifying = false
    private(set) var isInvalidated = false

    /// Test hooks (`TestHost`). Nil in production shells. `didCommit`'s action is `nil` for a
    /// modification made by an effect.
    var didCommit: ((Action?, State) -> Void)?
    var effectsDidChange: (() -> Void)?

    init(isolation: any Actor, initialState: State, interactor: AnyInteractor<State, Action>,
         areStatesEqual: ((State, State) -> Bool)?)

    var state: State {
        registrar.access(self, keyPath: \.state)
        return _state
    }
    /// The committed value without registering an observation access (`Effects`, `TestHost`).
    var committedState: State { _state }

    @discardableResult
    func send(_ action: Action) -> Task<Void, Never>? {
        guard !isInvalidated else { reportIssue("Can't send \(action) to an invalidated model"); return nil }
        guard !isRoutingAction, !isModifying else {
            reportIssue("Can't send another action before handling this one; use effects.perform { try effects.send(action) }")
            return nil
        }
        let rootPath = [enumTag(action)]
        isRoutingAction = true
        performContext = PerformContext(visitedPaths: [rootPath])
        var working = _state
        interactor.interact(state: &working, action: action, effects: Effects(core: self, path: rootPath))
        let visited = performContext!.visitedPaths
        performContext = nil
        commit(working)
        for path in visited { cancelTasks(at: .anonymous(path)) }
        isRoutingAction = false
        didCommit?(action, _state)
        return startQueued().all
    }

    /// A state change from an effect. Same working copy and commit rules as `send`; no perform
    /// context (so `perform` inside `body` is reported and dropped), no auto-cancel, no task.
    func modify(_ body: (inout State) -> Void) {
        guard !isRoutingAction else {
            reportIssue("Can't modify state from effects during interact; mutate the 'state' argument instead"); return
        }
        guard !isModifying else { reportIssue("Can't modify state inside another 'modify'; dropped"); return }
        isModifying = true
        defer { isModifying = false }
        var working = _state
        body(&working)
        commit(working)
        didCommit?(nil, _state)
    }

    func invalidate() {
        isInvalidated = true
        for tracked in tasks.values.joined() { tracked.task.cancel() }
        tasks.removeAll(); queued.removeAll()
    }

    var inFlightTasks: [Task<Void, Never>] { tasks.values.joined().map(\.task) }
}
```

`commit` is the unified-feature-state §5.2 commit path moved verbatim from `ViewModel`, now shared by
`send` and `modify`: content-equal wholesale replacement keeps the current value; otherwise store,
and fire the coarse `\.state` key path only when the root `_$id` changed. A `modify` whose body
mutates members in place notifies those members (shared registrars) and nothing else.

Effect start — the one place that vouches for safety, and the shape the spikes proved (a `for`
loop directly in the `assumeIsolated` body; see §10 for why not `map`):

```swift
private func startQueued() -> [Task<Void, Never>] {
    let effects = queued            // snapshot: a nested send from a preamble must not see these
    queued.removeAll()
    var started: [Task<Void, Never>] = []
    for effect in effects {
        guard !isInvalidated else { break }
        guard let operation = effect.operation else {    // a queued `cancel(_:)`: runs in order
            cancelTasks(at: effect.location); continue
        }
        // NB: `operation` is non-Sendable but only ever runs on `isolation`, which is the current
        //     isolation (`assumeIsolated` traps otherwise). The compiler cannot relate the dynamic
        //     `any Actor` to the `@isolated(any)` task closure.
        nonisolated(unsafe) let operation = operation
        let token = effect.token
        if case .identified = effect.location { cancelTasks(at: effect.location) }   // replace per key
        let task = isolation.assumeIsolated { _ in
            Task.immediateIfAvailable {              // starts now, here; resumes here after every await
                do { try await operation() }
                catch is CancellationError {}
                catch { reportIssue("Effect threw: \(error)") }
                self.taskDidFinish(token)            // on `isolation`: prune + TestHost signal
            }
        }
        track(TrackedEffect(token: token, task: task), at: effect.location)
        started.append(task)
    }
    effectsDidChange?()
    return started
}
```

Anonymous effects of one send are all tracked (no intra-send replacement: two `Merge` children
performing for one action both run; re-handling the case cancels both). Identified effects replace
the previous run of the same key. `isRunning(_:)` is `tasks[.identified(scope, key)] != nil`.
`taskDidFinish` removes the entry, so `tasks` holds only in-flight
effects and `inFlightTasks` is exact — `TestHost.finish` and `skipInFlightEffects` rely on this.

### 3.4 Enum tags and the `Task` helpers

- `enumTag(_:)` wraps TCA 2's `_enumTag(of:)` (runtime metadata, payload-independent, no C shim).
  A non-enum `Action` has no tag; every action then shares one path and re-sending any action
  cancels all anonymous effects. `Action` is an enum in every Lattice feature; this is documented,
  not diagnosed.
- `Task.immediateIfAvailable` (TCA 2 `Internal/Task.swift`, verbatim): OS 26 → `Task.immediate`;
  older OS on the main actor → `Task.startOnMainActor` (`@_silgen_name` binding to the stdlib
  entry point, available since iOS 17 / macOS 14); older OS on another actor → plain `Task` (never
  reached: actor shells are OS 26+).
- `[Task<Void, Never>].all`: the aggregate returned by `send`; `nil` for zero tasks; cancelling it
  cancels every effect of that send.

## 4. Interactor contracts

### 4.1 `Interactor`

```swift
public protocol Interactor<State, Action> {
    associatedtype State
    associatedtype Action
    associatedtype Body: Interactor
    @InteractorBuilder<State, Action> var body: Body { get }
    /// Mutates state synchronously and enqueues effects. Never suspends; never sends.
    func interact(state: inout State, action: Action, effects: Effects<State, Action>)
}

extension Interactor where Body: Interactor<State, Action> {
    public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {
        body.interact(state: &state, action: action, effects: effects)
    }
}

public typealias InteractorOf<I: Interactor> = Interactor<I.State, I.Action>

public struct AnyInteractor<State, Action>: Interactor {
    public init<I: Interactor>(_ base: I) where I.State == State, I.Action == Action
    public func interact(state: inout State, action: Action, effects: Effects<State, Action>)
}
extension Interactor { public func eraseToAnyInteractor() -> AnyInteractor<State, Action> }
```

`InteractorBuilder<State, Action>` loses its `Sendable` constraints; its existential
`buildExpression`, `buildOptional` and `buildLimitedAvailability` erase with
`eraseToAnyInteractor()`. The `@Interactor<State, Action>` macro is unchanged (conformance
extension, typealiases, builder attribute).

### 4.2 Operators

```swift
public struct Interact<State, Action>: Interactor {
    public typealias Handler = (inout State, Action, Effects<State, Action>) -> Void
    public init(handler: @escaping Handler)
}

extension Interactors {
    /// Runs both for every action, in order, with the same handle. Their effects start in that order.
    public struct Merge<I0: Interactor, I1: Interactor<I0.State, I0.Action>>: Interactor
    public struct MergeMany<Element: Interactor>: Interactor
    public struct Conditional<First: Interactor, Second: Interactor<First.State, First.Action>>: Interactor
    public struct CollectInteractors<State, Action, Interactors: Interactor>: Interactor
}
public struct EmptyInteractor<State, Action>: Interactor
```

`When` keeps its raw key-path / case-path state access and derives the child handle:

```swift
extension Interactors {
    public struct When<ParentState, ParentAction, Child: Interactor>: Interactor {
        public init<ChildState, ChildAction>(
            state: WritableKeyPath<ParentState, ChildState>, action: CaseKeyPath<ParentAction, ChildAction>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
        ) where ChildState == Child.State, ChildAction == Child.Action
        public init<ChildState, ChildAction>(
            state: CaseKeyPath<ParentState, ChildState>, action: CaseKeyPath<ParentAction, ChildAction>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
        ) where ChildState == Child.State, ChildAction == Child.Action

        public func interact(state: inout ParentState, action: ParentAction, effects: Effects<ParentState, ParentAction>) {
            guard let childAction = toChildAction.extract(from: action) else { return }
            let childEffects = effects.scope(
                extract: { toChildState.extract(from: $0) },          // key path: `{ $0[keyPath: kp] }`, never nil
                embed: { toChildAction.embed($0) },
                embedState: { toChildState.embed(&$0, $1) },         // key path: `$0[keyPath: kp] = $1`; case path: `$0 = casePath.embed($1)`
                childTag: enumTag(childAction),
                scopeEntry: toChildState.scopeEntry                    // AnyHashable(keyPath) or AnyHashable(caseKeyPath)
            )
            switch toChildState {
            case .keyPath(let keyPath):
                child.interact(state: &state[keyPath: keyPath], action: childAction, effects: childEffects)
            case .casePath(let casePath):
                guard var childState = casePath.extract(from: state) else { return }
                defer { state = casePath.embed(childState) }
                child.interact(state: &childState, action: childAction, effects: childEffects)
            }
        }
    }
}
```

The child path `[tag(parentAction), tag(childAction)]` gives the auto-cancel granularity a child
expects: `.child(.other)` does not cancel `.child(.start)`'s effects; re-sending `.child(.start)`
does; a parent interactor that performs for `.child(…)` sits at `[tag(child)]` and is cancelled by
any child action. A case-scoped child whose case is no longer active changes nothing: its handle
reports a stale `send` (returning `nil`) or a stale `modify` (dropping the body). A live child's
`modify` is one parent commit written back through `embedState`.

`Debounce` becomes an operation transform; cancel-in-flight is auto-cancel. It holds no
per-instance token, so it works identically whether built once or inside `body` on every action
(today's `Interactors.Debounce` mints a fresh `DebounceToken` per instance and, built inside `body`
as the README shows, never debounces):

```swift
extension Interactors {
    /// Delays every effect the child performs by `duration`. Re-handling the action case cancels
    /// the previous delayed effects, so rapid repeats coalesce to the last one.
    public struct Debounce<C: Clock, Child: Interactor>: Interactor {
        public init(for duration: C.Duration, clock: C, child: () -> Child)
        public func interact(state: inout Child.State, action: Child.Action, effects: Effects<Child.State, Child.Action>) {
            child.interact(state: &state, action: action, effects: effects.transformingOperations { operation in
                { try await clock.sleep(for: duration); try await operation() }
            })
        }
    }
}
extension Interactors.Debounce where C == ContinuousClock { public init(for duration: Duration, child: () -> Child) }
```

The former `.observe` / `.merge` / `.append` restrictions disappear: there is one primitive, and a
stream is a `for await` inside it. The former `.merge` concurrency becomes interleaving on one
isolation: effects of one send start in order and overlap only at their suspension points.

## 5. Interface boundaries

### 5.1 `Feature`

```swift
public protocol FeatureProtocol {
    associatedtype Action
    associatedtype State: FeatureState
    var interactor: AnyInteractor<State, Action> { get }
    var areStatesEqual: ((State, State) -> Bool)? { get }
}

public struct Feature<Action, State: FeatureState>: FeatureProtocol {
    public init<I: Interactor>(interactor: I, areStatesEqual: ((State, State) -> Bool)?) where I.State == State, I.Action == Action
    public init<I: Interactor>(interactor: I) where I.State == State, I.Action == Action
}
extension Feature where State: Equatable {
    public init<I: Interactor>(interactor: I) where I.State == State, I.Action == Action   // `==`
}
```

### 5.2 `ViewModel`

```swift
@MainActor @dynamicMemberLookup
public final class ViewModel<F: FeatureProtocol>: Observable {
    public typealias Action = F.Action
    public typealias State = F.State
    private let core: Core<State, Action>

    public init(initialState: State, feature: F) {
        core = Core(isolation: MainActor.shared, initialState: initialState,
                    interactor: feature.interactor, areStatesEqual: feature.areStatesEqual)
    }

    public var viewState: State.ViewState { State.ViewState(state) }
    public subscript<V>(dynamicMember keyPath: KeyPath<State.ViewState, V>) -> V { State.ViewState(state)[keyPath: keyPath] }

    /// Processes the action synchronously (state, auto-cancel, effect preambles) and returns the
    /// task for the effects it started, or `nil` when it started none.
    @discardableResult
    public func sendViewEvent(_ event: Action) -> Task<Void, Never>? { core.send(event) }

    /// Raw state; internal for `ScopedViewModel` and bindings. Registers on the core's registrar.
    var state: State { core.state }

    #if swift(<6.4)
      @_optimize(none)
    #endif
    isolated deinit { core.invalidate() }
}
```

`Observable` conformance stays for `@Bindable`; the registrar lives in `Core`, which is what
`withObservationTracking` records. `ScopedViewModel.sendViewEvent` and the `_send` closure return
`Task<Void, Never>?`; bindings discard it. Scoping and binding overloads are otherwise unchanged.

```swift
.refreshable { await viewModel.sendViewEvent(.refresh)?.value }
```

### 5.3 `ActorModel`

```swift
/// A feature running on its own serial executor, off the main actor: for non-view-bound features
/// and for parallel tests. Child models created later share this isolation.
@available(iOS 26, macOS 26, watchOS 26, *)
public actor ActorModel<F: FeatureProtocol> {
    public typealias Action = F.Action
    public typealias State = F.State
    private let isolation: DefaultIsolation      // `private actor DefaultIsolation {}`, file scope, non-generic
    private let core: Core<State, Action>

    public nonisolated var unownedExecutor: UnownedSerialExecutor { isolation.unownedExecutor }

    public init(initialState: State, feature: F) async {
        let isolation = DefaultIsolation()
        self.isolation = isolation
        core = Core(isolation: isolation, initialState: initialState,
                    interactor: feature.interactor, areStatesEqual: feature.areStatesEqual)
    }

    public var state: State { core.state }
    @discardableResult public func send(_ action: Action) -> Task<Void, Never>? { core.send(action) }

    isolated deinit { core.invalidate() }
}
```

The actor's executor *is* the core's isolation, so `core.send`'s `assumeIsolated` holds inside
every actor method, and effect tasks are serialized with them. `init` is `async` because a non-main
actor's initializer is isolated only when async. Every shell's `isolated deinit` carries the
`#if swift(<6.4) @_optimize(none)` guard shown on `ViewModel` (TCA 2 `Store.swift:46-51`; CI builds
with Swift 6.3.1).

The core's isolation is a plain `any Actor` bound at construction, as in TCA 2, rather than the
`isolated any Actor` parameter of Point-Free's video #382/#383, for two reasons. A separate
`DefaultIsolation` object is the only shape that does not form a retain cycle: binding `self` would
make `shell → core → isolation` a cycle and `isolated deinit` would never run. And an `isolated`
parameter cannot be satisfied for a separate object — `core.bind(to: isolation)` from the actor's
`init` is `error: actor-isolated instance method 'bind(to:)' cannot be called from outside of the
actor` (`/tmp/lattice-spikes/isolated-param/`). Construction-site discipline is therefore the
guarantee: exactly two places bind an isolation (`ViewModel.init` → `MainActor.shared`;
`ActorModel.init`/`TestModel.init` → their own `DefaultIsolation()`), and the single runtime check
is `assumeIsolated` at effect start.

### 5.4 `TestHost` (internal)

Shared by both test shells; nonisolated and non-Sendable like `Core`, and only touched on the test
shell's isolation (its `async` members are `nonisolated(nonsending)`, so they run where called).

```swift
final class TestHost<State: FeatureState, Action> {
    let core: Core<State, Action>
    var exhaustivity: Exhaustivity = .on
    var timeout: Duration = .seconds(1)
    private let areStatesEqual: (State, State) -> Bool
    private var assertedState: State                      // baseline for the next assertion
    private var pending: [Received<State, Action>] = []   // effect-originated commits: (action: Action?, resultingState)
    private var isTestSend = false
    private let signal: AsyncStream<Void>; private let continuation: AsyncStream<Void>.Continuation  // bufferingNewest(1)

    init(isolation: any Actor, initialState: State, feature: some FeatureProtocol<State, Action>, …) {
        core.didCommit = { [unowned self] action, state in
            if isTestSend, action != nil { isTestSend = false; assertedState = state; return }   // the root transition of the send under test
            pending.append(.init(action: action, resultingState: state)); continuation.yield()   // action == nil: a modification
        }
        core.effectsDidChange = { [unowned self] in continuation.yield() }
    }

    var state: State { assertedState }

    /// Exhaustive: fails if anything is pending. Baseline = the state right after the root
    /// transition; then folds every modification committed synchronously during this send (effect
    /// preambles) into the assertion, so one `update` describes the action's change and theirs.
    func send(_ action: Action, assert update: ((inout State) throws -> Void)?, at: TestIssueLocation) -> Task<Void, Never>?

    /// Waits on `signal` until a matching pending action exists, or nothing is in flight and nothing
    /// matches (fails immediately), or `timeout` elapses (one detached deadline task yields the
    /// signal; no polling). Folds the modifications pending before the match and those already
    /// committed after it into the assertion. Exhaustive: a non-matching pending action fails.
    func receive(matching: (Action) -> Bool, description: String, timeout: Duration?, assert: …, at: …) async

    /// Synchronous. Folds every pending modification into one assertion against `assertedState +
    /// update`; with nothing pending, asserts the live state. Pending actions fail first (they need
    /// `receive`). This is how tests assert results that effects wrote directly.
    func expect(_ update: (inout State) throws -> Void, at: …)

    /// Awaits `core.inFlightTasks` until none remain (re-reading after each wave, since effects
    /// start effects), failing after `timeout`; then fails on anything still pending when exhaustive.
    func finish(timeout: Duration?, at: …) async

    func skipReceived(strict: Bool, at: …)                     // advances `assertedState` past every pending entry
    func skipInFlightEffects(strict: Bool, at: …) async        // cancels in-flight tasks, awaits them
}
```

`send` is synchronous: when `core.send` returns, every synchronous consequence has happened, and
every effect without a real suspension has already committed its modifications or delivered its
sends into `pending`. `receive`, `expect` and `finish` suspend only on the signal stream, never on
`Task.yield` loops, `Task.sleep` polling or `megaYield`.

Exhaustive mode (`.on`) requires every commit to be described: pending actions through `receive`,
pending modifications through `expect` (or folded into the enclosing `send`/`receive`). Anything
still pending at the next `send`/`expect`, at `finish` or at deinit is reported. A modification
whose resulting state equals the previous one is exempt. In `.off` mode, pending entries are
skipped to the latest state before the next assertion (reported when `showSkippedAssertions`).

### 5.5 `TestModel`

```swift
/// The test shell. Runs the feature on its own executor, so suites need not be `@MainActor` and
/// run in parallel. The interactor and the test must not be main-actor-isolated (§10).
@available(iOS 26, macOS 26, watchOS 26, *)
public actor TestModel<F: FeatureProtocol> {
    public typealias Action = F.Action
    public typealias State = F.State
    public nonisolated var unownedExecutor: UnownedSerialExecutor { isolation.unownedExecutor }

    public init(initialState: State, feature: F, exhaustivity: Exhaustivity = .on, timeout: Duration = .seconds(1),
                fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) async
    public init(initialState: State, feature: F, areStatesEqual: @escaping (State, State) -> Bool,
                exhaustivity: Exhaustivity = .on, timeout: Duration = .seconds(1)) async

    public var state: State { host.state }
    public func setExhaustivity(_ exhaustivity: Exhaustivity)     // cross-actor property writes are not expressible

    @discardableResult
    public func send(_ action: Action, assert update: ((inout State) throws -> Void)? = nil,
                     fileID: … line: … column: …) -> Task<Void, Never>?

    public func receive(_ expectedAction: Action, timeout: Duration? = nil, assert update: ((inout State) throws -> Void)? = nil, …) async where Action: Equatable
    public func receive(_ isMatching: (_ action: Action) -> Bool, timeout: Duration? = nil, assert update: …, …) async
    public func receive<Value>(_ actionCase: KeyPath<Action.AllCasePaths, AnyCasePath<Action, Value>>, timeout: Duration? = nil, assert update: …, …) async where Action: CasePathable

    public func finish(timeout: Duration? = nil, …) async
    /// Asserts modifications made by effects (synchronous; see `TestHost.expect`).
    public func expect(_ update: (inout State) throws -> Void, fileID: … line: … column: …)
    public func skipReceived(strict: Bool = true, …)
    public func skipInFlightEffects(strict: Bool = true, …) async

    isolated deinit { host.core.invalidate() }
}
```

```swift
@Test func search() async {                      // not @MainActor; suite runs in parallel
    let clock = TestClock()
    let model = await TestModel(initialState: SearchState(), feature: Feature(interactor: SearchInteractor(clock: clock)))
    await model.send(.queryChanged("a")) { $0.query = "a" }
    await model.send(.queryChanged("b")) { $0.query = "b" }   // auto-cancels "a"'s debounced effect
    await clock.advance(by: .milliseconds(300))
    await model.expect { $0.results = ["b"] }                   // the effect wrote the results directly
    await model.finish()
}

@Test func timer() async {
    let clock = TestClock()
    let model = await TestModel(initialState: TimerState(), feature: Feature(interactor: TimerInteractor(clock: clock)))
    await model.send(.start)
    await clock.advance(by: .seconds(3))
    await model.expect { $0.ticks = 3 }                          // three modifications, one assertion
    await model.send(.stop)                                      // auto-cancels .start's effect
    await model.finish()
}
```

### 5.6 `TestViewModel`

Same surface as `TestModel`, as a `@MainActor final class` over the same `TestHost` with
`isolation: MainActor.shared`: `exhaustivity` and `timeout` are settable properties, `init` is
synchronous, `send` is synchronous. For interactors that are main-actor-isolated (declared in a
module with main-actor default isolation, or capturing `@MainActor` values) and for tests that must
run on the main actor. `TestEventTask`, `InFlightEffectRecord` and `RootSendOrigin` are removed;
`PendingReceive` becomes `Received` (optional action, resulting state); `skipReceivedActions`
becomes `skipReceived` (it skips modifications too); `Exhaustivity`, `TestFailure` and
`TestIssueReporting` are kept.

## 6. Isolation and scheduling guarantees

These are the behaviours the suite asserts; each was reproduced in the spikes (§11) with the exact
shape in §3.

| Scenario | Guarantee |
|---|---|
| `sendViewEvent` / `send` returns | all synchronous `interact` logic has run; every effect of this send has run to its first suspension; every send those preambles made has been processed (depth-first), including *its* effect preambles |
| Effect suspends (`await` on a dependency, `Task.sleep`, `TestClock.sleep`, `AsyncStream` iteration) | resumes on the shell's isolation; `effects.send` after it is a synchronous re-entry with no hop |
| `effects.send` during `interact` | issue reported, `nil`, state untouched |
| `effects.perform` outside `interact` | compile error inside async contexts (`noasync`); issue reported and dropped from a synchronous escape |
| `effects.state` during `interact` | issue reported; returns the committed pre-action value; no exclusivity trap |
| Observer re-reads the model synchronously during a mutation | reads the previous committed value (working copy); no trap |
| `.search("a")` then `.search("b")` with a sleeping effect | the first effect is cancelled at its suspension point; only `.results("b")` can arrive |
| `.child(.other)` after `.child(.start)` | `.child(.start)`'s effect keeps running; `.child(.start)` again cancels it; a root `.other` does not |
| Same case re-sent while its effect ignores cancellation (`Task.yield` then `send`) | the send is delivered: 100 increments + 100 decrements → 0 |
| Case-scoped child's case switched away, then its effect sends | issue reported, dropped |
| `Merge(i0, i1)` both perform for `.go` | both start in one send, in order; re-sending `.go` cancels both |
| `@EffectID var search` on a child built inside `body` | `.child(.start)` then `.child(.cancel)` cancels the running effect even though each `interact` built a new child (declaration-site key) |
| `When(\.a) { Child() }` and `When(\.b) { Child() }`, both performing under the child's one key | independent: `.a(.cancel)` cancels only `a`'s effect (scope path) |
| `effects.cancel(x)` then `effects.isRunning(x)` in the same `interact` | `true` (the cancel is queued); `false` from the next action on |
| `await send(.a)?.value` | waits for `.a`'s effects only; effects started by nested sends are not covered |
| Shell deallocated while an effect sleeps | `isolated deinit` cancels it; `effects.send`/`effects.modify` then throw `CancellationError` without an issue (task is cancelled) |
| `effects.modify { $0.x = y }` from an effect | one commit through the shared commit path: members touched in place notify their observers only; a content-equal replacement notifies nothing; `didCommit(nil, state)` |
| `effects.modify` during `interact`, or inside another `modify` body | issue reported, body not run |
| `effects.send` / `effects.perform` inside a `modify` body | issue reported, dropped (the enclosing commit is not overwritten by a nested one) |
| Case-scoped child's case switched away, then its effect modifies | issue reported, dropped; the parent state is untouched |
| Effect preamble modifies before its first suspension | committed inside `send`; `viewModel.state` already reflects it when `sendViewEvent` returns; `TestModel.send`'s `assert` describes the root transition plus that modification |
| Effect modifies after a suspension | committed when it resumes on the shell; pending for `expect` (or folded into the next `receive`) |
| `core.send` from the wrong isolation | traps in `assumeIsolated` when the send starts an effect (the only dynamic isolation check, as in TCA 2). A send that starts none is not checked at runtime; the §8 regression test guards the library against the bug class that can produce one |
| 100 `TestModel`s × 1 ms blocking effect | parallel on the cooperative pool (spike: 0.06 s vs 0.66 s on the main actor) |

## 7. Migration

| Before | After |
|---|---|
| `func interact(state: inout State, action: Action) -> Emission<Action>` | `func interact(state: inout State, action: Action, effects: Effects<State, Action>)` |
| `Interact { state, action in … return .none }` | `Interact { state, action, effects in … }` |
| `return .action(.next)` | `effects.perform { try effects.send(.next) }` — only when `.next` must start effects or run interactor logic; otherwise do the work in place |
| `return .perform { [api] in .loaded(try await api.fetch()) }` + `case .loaded(let x): state.x = x` | `effects.perform { let x = try await api.fetch(); try effects.modify { $0.x = x } }` — no response case, no capture list, `api` need not be `Sendable` |
| `return .observe { stream }` + `case .value(let v): …` | `effects.perform { for await v in stream { try effects.modify { $0.apply(v) } } }` |
| `return .merge([a, b])` / `.append(a, b)` | two `perform` calls / one `perform` doing both sequentially |
| `Emission.debounce(using: Debouncer)`, `Debouncer` | `Interactors.Debounce(for:clock:)` around the child, or `try await clock.sleep(for:)` at the top of the effect |
| Cancel-in-flight | automatic per action case; `@EffectID var x` on the interactor + `effects.perform(id: x)` / `effects.cancel(x)` / `effects.isRunning(x)` for explicit control (per row: `$x.scoped(row.id)`) |
| `struct FooInteractor: Sendable`, `protocol FooClient: Sendable`, actor test doubles | no `Sendable`; plain classes/closures as dependencies (methods `nonisolated(nonsending)` unless the module enables `NonisolatedNonsendingByDefault`) |
| `uncheckedSendable()`, `eraseToAnyInteractorUnchecked()`, `UncheckedSendableInteractor` | removed; `eraseToAnyInteractor()` has no constraint |
| `sendViewEvent(_:) -> EventTask`; `await task.finish()`; `task.cancel()` | `-> Task<Void, Never>?`; `await task?.value`; `task?.cancel()` |
| `TestViewModel` (`@MainActor`, `send` is `async`) | `TestModel` (actor, `await model.send(…)`, suites not `@MainActor`); `TestViewModel` kept for main-actor-isolated interactors |
| `await test.receive(.loaded(x)) { $0.x = x }` for an effect's result | `await test.expect { $0.x = x }` (the effect modified state; nothing to receive). `receive` remains for actions an effect sends |
| `skipReceivedActions(strict:)` | `skipReceived(strict:)` |
| `TestEventTask`, `skipInFlightEffects` semantics | `Task<Void, Never>?`; `skipInFlightEffects` unchanged in meaning |
| `Package.swift` | `+ .enableUpcomingFeature("NonisolatedNonsendingByDefault")` on `Lattice`; podspec `OTHER_SWIFT_FLAGS += -enable-upcoming-feature NonisolatedNonsendingByDefault`, `swift_version = '6.2'` |

```swift
@FeatureState
struct CounterState: Equatable {
    var count = 0
    var isRefreshing = false
    @Domain var lastUpdatedAt: Date?
    var countText: String { "\(count)" }
}

enum CounterAction { case task, cancelRefresh }                              // no response case

protocol CounterClient { func fetch() async throws -> CounterAPIModel }   // not Sendable

@Interactor<CounterState, CounterAction>
struct CounterInteractor {
    @EffectID var refresh                                                      // identity lives on the interactor
    let counterClient: CounterClient
    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .task:
                state.isRefreshing = true
                effects.perform(id: refresh) {
                    defer { try? effects.modify { $0.isRefreshing = false } }   // also runs when cancelled
                    let model = try await counterClient.fetch()
                    try effects.modify {
                        $0.count = model.count
                        $0.lastUpdatedAt = model.updatedAt
                    }
                }
            case .cancelRefresh:
                effects.cancel(refresh)
            }
        }
    }
}

@Test func hydrates() async {
    let model = await TestModel(initialState: CounterState(), feature: Feature(interactor: CounterInteractor(counterClient: StubClient(count: 4))))
    await model.send(.task) { $0.isRefreshing = true }?.value
    await model.expect { $0.count = 4; $0.lastUpdatedAt = StubClient.date; $0.isRefreshing = false }
}
```

## 8. Verification

| Layer | Mechanism |
|---|---|
| Isolation regression | `Tests/LatticeTests/IsolationTests/`: effect literal formed in a **nonisolated** context, run under `TestModel`, asserting `core.isolation.assertIsolated()` (via `@testable` access) after `Task.yield()` and after `TestClock.sleep`; the same under `ViewModel` with `MainActor.assertIsolated()`. This is the only test shape that detects the `.map` isolation loss (§10). |
| Exit tests | `#expect(processExitsWith: .failure)`: `core.send` from `Task.detached` with an action that performs an effect; `effects.state` is *not* an exit test (reports, returns last known). |
| Scheduling | §6 rows as `TestModel`/`ViewModel` tests: preamble-before-return log order, depth-first nested send order, `defer`-before-effect, 100× yield counter → 0 (modification-based and send-based variants), sleep variant loses the cancelled ones, non-transitive `send` task, deinit → `CancellationError` for `send` and `modify`. |
| Modification | `modify` guards (during `interact`, nested in `modify`, stale case-scoped child, invalidated → throw), `perform`/`send` inside a body dropped, one notification per `modify` however many members change, content-equal replacement silent, `When` key-path and case-path write-back, preamble modification visible on return. |
| Auto-cancel | per-case, per-path (`When` key path and case path), `Merge` both-start/both-cancel; identified: `@EffectID` keys equal across rebuilt child instances and across generic specializations, replace per key from any case, `cancel` queued from `interact` runs in order, immediate from an effect, `isRunning` from `interact` and from the effect's own preamble, the two-`When`s-same-child collision resolved by `scopePath` (and failing without it), per-row keys via `scoped(_:)`; tag stability across payloads and `indirect`. |
| Observation | existing `PresentationTests` suites run unchanged against `Core`'s commit path (`FineGrainedObservationTests`, `ViewModelObservationTests`, `ViewModelReentrancyTests`, `EnumCaseScopingTests`, `ScopedViewModelTests`). |
| Test infrastructure | `TestingInfrastructureTests` ported to `TestModel`: send/receive (equatable, predicate, case path), `expect` (pending modifications folded; live state when none; pending action fails), folding of preamble modifications into `send` and of surrounding modifications into `receive`, exhaustivity on/off incl. unasserted-modification reports at `send`/`expect`/`finish`/deinit and the no-op exemption, `finish` timeout, `skipReceived`, `skipInFlightEffects`, missing-equality issue; one mirror suite on `TestViewModel`. |
| Negative compile checks | `scripts/negative-compile-checks.sh` gains an `-emit-sil -wmo -o /dev/null` lane (region-isolation diagnostics are not produced by `-typecheck`) with fixtures: `PERFORM_IN_EFFECT` (`'perform' is unavailable from asynchronous contexts`), `MAINACTOR_INTERACTOR_TO_TESTMODEL` (`sending main actor-isolated 'interactor' to actor-isolated initializer`), `NO_SENDABLE_BASELINE` (non-Sendable state/action/dependency compiles with `-warnings-as-errors`). |
| Parallelism | `@Test(arguments: 1...500)` under `TestModel` with a 1 ms blocking effect; asserts wall time < the serial `ViewModel` variant. |
| Integration | example packages build and their tests pass under `TestModel`. |

## 9. Phases

Each phase is a PR on the feature branch; the package builds and tests pass at every phase end.

### Phase 1 — Core, Effects, interactors, `ViewModel`

- Add `Effects.swift`, `Core.swift`, `Runtime/{EnumMetadata,RuntimeMetadata}.swift`,
  `Concurrency/{Task+Immediate,StartOnMainActor}.swift`; `Package.swift` upcoming feature.
- Rewrite `Interactor.swift`, `InteractorBuilder.swift`, `Interactors/*` (§4); `Feature.swift`
  (§5.1); `ViewModel.swift` as a shell (§5.2); `ScopedViewModel`/`ViewModelBinding` return types.
- Delete `Emission.swift`, `Emission+Debounce.swift`, `DynamicState.swift`, `Internal/Execution/*`,
  `Debouncer.swift`, `DebounceResult.swift`, `EffectCancellationRegistry.swift`,
  `EffectTaskRegistry.swift`, `Send.swift`, `UncheckedSendable.swift`, `EventTask.swift`, and the
  tests that exist only to exercise them (`EmissionExecutionTests`, `RootScopeTasksTests`,
  `EmissionAppendTests`, `EmissionAppendObserveTests`, `EmissionDebounceTests`, `DebouncerTests`,
  `EventTaskTests`, `ViewModelAppendTests`).
- Tests: `PresentationTests` ported (interactor fixtures gain the `effects` parameter; effect
  assertions go through `await viewModel.sendViewEvent(…)?.value`); `IsolationTests` (§8 rows 1–4
  on `ViewModel`); `DomainTests` operator tests ported to drive `ViewModel` directly.

### Phase 2 — Test infrastructure

- Add `Testing/TestHost.swift`, `Testing/TestModel.swift`; rewrite `TestViewModel.swift` over the
  host; `PendingReceive.swift` → `Received.swift`; delete `TestEventTask.swift`,
  `InFlightEffectRecord.swift`, `RootSendOrigin.swift`.
- Port `TestingInfrastructureTests` and the `CounterInteractors` tests to `TestModel`; drop
  `@MainActor` from every suite whose fixtures are nonisolated; `IsolationTests` rows under
  `TestModel` (the `.map` regression guard lives here).

### Phase 3 — `ActorModel`

- Add `Presentation/ActorModel/ActorModel.swift` (§5.3) and its tests: §6 rows under `ActorModel`,
  the parallelism test, `isolated deinit` cancellation.

### Phase 4 — Debounce and examples

- `Interactors.Debounce` (§4.2) with `TestClock` tests; per example package (`Search`, `Todos`,
  `Phase`, `TimerLeak`, `ScopedComposition`, `FineGrained`): interactors to `effects`, dependencies
  lose `Sendable`, tests to `TestModel`.

### Phase 5 — Documentation

- README, `AGENTS.md`, `skills/**` (+ `scripts/sync-skills.sh`), `specs/`: replace
  `view-model-event-loop-and-emission-handling.md` with `effects-and-isolation.md`; rewrite
  `interactors.md`, `testing-infrastructure.md`; update `view-model.md`, `README.md`;
  `Lattice.podspec` (§7); mark this plan complete.

## 10. Limitations

- **Interactors must be nonisolated.** An interactor type or `Interact` closure formed in
  main-actor-isolated code (a module with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, or `@MainActor`
  context) is a main-actor value: passing it to `TestModel`/`ActorModel` is a compile error
  (`sending main actor-isolated 'interactor' to actor-isolated initializer`), and a `@MainActor` test
  cannot call `TestModel.receive` because its closures are main-actor values too. Such features use
  `ViewModel`/`TestViewModel`. Executor sharing cannot lift this: the checker reasons about
  isolation domains, not executors.
- **Consumer async dependencies.** Effect closures are `nonisolated(nonsending)` regardless of the
  consumer's settings, but a plain `func fetch() async` declared in a module *without*
  `NonisolatedNonsendingByDefault` is `@concurrent`: calling it on a captured non-Sendable
  dependency is a compile error (`sending 'api' risks causing data races`), and on a disconnected
  one it runs off the shell's isolation. Consumers enable the feature or mark such methods
  `nonisolated(nonsending)`.
- **Auto-cancel is cancellation-cooperative.** Re-handling a case cancels its anonymous effects'
  tasks; work is lost only at cancellation-aware suspension points (`Task.sleep`, cancellable
  APIs). Effects that must survive re-sends use `perform(id:)` with an `@EffectID` key.
- **Non-transitive `send` task.** `await send(.a)?.value` does not wait for effects started by
  sends made from `.a`'s effects.
- **Results are modifications, not actions.** An effect's result goes into state through
  `effects.modify`; `effects.send` is only for starting effects, running interactor logic or
  auto-cancelling. Consequences: a modification runs no interactor logic (a parent or `Merge`
  sibling cannot react to it — send an action when one must), a modification cannot start effects
  (`perform` is `interact`-only; continue sequentially in the same task or send an action), and
  modifications are anonymous in tests (`expect` asserts the state diff; several modifications
  pending at once are described by one `expect`).
- **`effects.state` is get-only.** A settable `effects.state.x = …` was prototyped and rejected: an
  accessor cannot throw when the model is gone (silent drop), traps on a stale case-scoped child,
  and commits once per statement.
- **Effects run on the shell.** CPU-bound work inside an effect runs on the main actor under
  `ViewModel`; move it behind a `@concurrent` function or a dependency with its own executor.
- **`ActorModel`/`TestModel` are OS 26+** (`Task.immediate` and actor `isolated deinit`, which the
  compiler requires at macOS 15.4 / iOS 18.4). `@available` goes on each `@Test`, not on `@Suite`.
- **Never create effect tasks inside a nested closure within `assumeIsolated`.** `ops.map { Task.immediateIfAvailable { … } }`
  compiles without diagnostics and starts the tasks synchronously, but they inherit *nonisolated*
  and resume on the global executor after their first suspension; tests whose effect literals are
  written in `@MainActor` code still pass. §8's regression test exists because of this; there is
  deliberately no per-send isolation assertion in `Core.send`.
- **`swiftc -typecheck` does not run region-isolation diagnostics**; concurrency negative checks
  use `-emit-sil -wmo`.
- `Action` should be an enum (§3.4).
- **`@EffectID` identity is the declaration site**, scoped by the `When` chain. Consequences: two
  instances of one child type in the *same* scope (`Merge(Child(), Child())` with no `When`) share a
  key, so the second replaces the first; every specialization of a generic interactor shares one
  key; a key built with a name at a call site is keyed by that call site (use `scoped(_:)` or one
  declaration for per-row identity); only the declaring handle's scope can cancel or query the key
  (a parent or a view cannot). Nothing about an effect's running state is observable — model it as
  state.
- Pre-OS-26 runtime paths (`startOnMainActor`, the `isolated deinit` main-actor back-deploy shim)
  were compile-checked at the floors and exercised only by direct call on an OS 27 host.

## 11. References

- Spike packages (Swift 6.4 / Xcode 27, all green at hand-off):
  `/tmp/lattice-spikes/isolation-mechanics` (`FINAL.md`: A1–A12 — isolation across suspension on
  both shells, preamble-before-return, lazy/depth-first/`defer` ordering, off-isolation trap exit
  tests, `isolated deinit` floors, `nonisolated(nonsending)` cross-module matrix, `for await` over
  non-Sendable elements at iOS 17, `noasync`, `assumeIsolated` result Sendability, 500× parallelism)
  and `/tmp/lattice-spikes/effects-core` (`FINAL.md` B1–B11 and `FOLLOWUP.md` B12–B16 — the §3
  `Core`/`Effects`/`EffectID` shape, `EnumMetadata` without the C shim, `When` tag paths, `Merge`,
  `Debounce` + `TestClock`, `ViewModel`/`ActorModel`/`TestModel`, TCA26-faithful `send`
  cancellation semantics, working-copy commit exit tests, main-actor interactor compile errors,
  `.map` isolation-loss reproduction; `SPIKE-C-FINAL.md` C1–C7 — `effects.modify` vs a settable
  `effects.state` on one commit path, `When` write-back through `embedState`, observation on
  modification, actionless test entries with `receive { … }`/folding shapes, 300/300 determinism
  for a modification-based counter, preamble-modification visibility, the nested-write hazard, and
  the inventory of what still needs `send`; `SPIKE-D-FINAL.md` D1–D4 — the `body`-rebuild identity
  problem, the declaration-keyed `@EffectID` wrapper (`#column` disambiguates one-line declarations;
  generic specializations share a key), the `scopePath` registry and the measured two-`When`s
  collision without it, queued `cancel` from `interact`, `isRunning` semantics, per-row `scoped(_:)`,
  and the A/B/C matrix). `/tmp/report-effect-identity.md`: TCA26 `@StoreTaskID` is a property wrapper
  over an `@Observable` reference `Storage`, declared in **State** in 14/14 example sites and kept
  alive across feature rebuilds by `_copyFeatureDynamicProperties` (machinery Lattice does not have);
  `@FeatureState` does not track `let` members but does project them unless `@Domain`; `body` is
  re-evaluated per action so `body`-built children are new values.
- Dead ends recorded there, not to be retried: the video's `init(isolation: isolated any Actor)` /
  `setIsolation(_: isolated any Actor)` binding (compile error against a separate isolation object,
  retain cycle against `self`; `/tmp/lattice-spikes/isolated-param/`); a per-send
  `preconditionIsolated()` in `Core.send` (rejected as a per-send cost; the §8 regression test
  covers the only case `assumeIsolated` does not); `.map`/`forEach` task creation inside
  `assumeIsolated`; array-level `nonisolated(unsafe)` without a per-element vouch (compile error);
  dropping `assumeIsolated` and calling `Task.immediateIfAvailable` directly (runtime trap);
  `send` throwing on `Task.isCancelled` (drops deliverable sends); mutating `core.state` in place
  during `interact` (exclusivity trap on re-entrant reads); a `TestModel(isolation: .main)` executor
  option (does not satisfy the static checker); TCA26's `run(_ body: sending (isolated Self) …)`
  (not callable with a closure literal from a consumer module — a `@Sendable` body is); a settable
  `effects.state` via `nonmutating _modify` (compiles, but cannot throw when the model is gone,
  traps on a stale case-scoped child and commits per statement); delivering effect results as
  response actions (the ping-pong this design exists to remove); a reference-type `EffectID` stored
  in state (per-row identity for free, but a fresh `State()` orphans running tasks, and an identity
  held by a `body`-built interactor is lost on every action); a key named at the call site
  (`EffectID("download-\(id)")` — keyed by the call site, so perform and cancel never match).
- TCA 2 (`/Users/michaelbattaglia/Documents/pointfree/TCA26/Sources/ComposableArchitecture2`):
  `Internal/Core.swift` (`RootCore.send`, `runHooks`, `withAddTaskContext` auto-cancel,
  `Storage.replaceTasks/trackTask`), `FeatureDynamicProperties/FeatureStore.swift` (`addTask`,
  `send` guards and messages, `modify` as the result path and its guards), `StoreActor.swift`
  (`DefaultIsolation` + `unownedExecutor`), `Internal/Task.swift`, `Internal/StartOnMainActor.swift`,
  `Internal/Runtime/EnumMetadata.swift`, `Testing/TestCore.swift` (signal stream, in-flight
  tracking, actionless `ReceivedInput` and the `send`/`receive`/`expect` folding rules),
  `Testing/TestStoreActor.swift`. Not copied: lifecycle modifiers, environment, spawn/scoped cores,
  `@Trigger`, hooks' task returned from `modify`, the TaskLocal exhaustivity trait.
  `/tmp/report-tca26-modify-from-tasks.md` records why TCA26 ships a `modify` closure rather than
  the video's settable state, the 15:1 `modify`:`send` ratio in its examples, and the three jobs
  `send` keeps.
- Point-Free, *Designing for Isolation: Nonisolated Core* (#382) and *Isolated Shell* (#383):
  `assumeIsolated { Task.immediate }` for isolation inheritance, lazy task start, no reentrant
  actions, `send` returning a task.
- Pre-refactor audits: `/tmp/report-lattice-sendable-audit.md` (annotation inventory, scheduling
  semantics, pre-existing defects fixed by construction here: `Emission.map(.observe)` task leak,
  `EventTask.finish()` cancellation, `RootScopeTasks` spin, `Emission.debounce` cancellation, and
  `Interactors.Debounce` built inside `body` minting a new `DebounceToken` per action so it never
  debounced — the new `Debounce` has no per-instance token) and `/tmp/report-tca26-isolation-trace.md`.

## 12. Implementation notes

Deviations from the text above that the implementation records, by spec section, each citing the
commit whose body records it. The §5.5 initializer note was found while writing the docs and is
marked so.

The phases landed in these commits:

- Phase 1: 95da2dc (library), 2b8694d (test port), 307b242 (review fixes).
- Phase 2: 381bbc0, 86d60a1 (library), 764a3f1, 199c95a (tests).
- Phase 3: c4a4fbb, 8c711cc.
- Phase 4: d3bc19f (Debounce tests); 60ef672, f50e4cd, b64efc6 (Search, Todos); 2db9f8f, de084e2,
  f6b644a, 5a25b14 (FineGrained, TimerLeak, ScopedComposition); 7631c1f (the §3.3 error exemption,
  an owner decision after the Phase 4 reviews).
- Phase 5: d24339e (specs; this close-out is the commit after it); README, `AGENTS.md`,
  `skills/**` and `Lattice.podspec` are step 5B.

Deviations:

- §3 (TCA 2 copies): the `Task.immediateIfAvailable` overloads are internal instead of `package`,
  because the CocoaPods build passes no `-package-name`; the four copied files are re-indented and
  otherwise identical (95da2dc).
- §3.1, §4.2: `Effects.scope` takes an extra internal `initialState:` that seeds the child's last
  known value, and `When` scopes only after resolving the child from the working state (a key path
  directly, a case path once `extract` succeeds). An action for an inactive case therefore returns
  early and no longer visits or auto-cancels the child path; the §3.1 shape had no child value to
  seed a non-optional box with (supervisor decision; 95da2dc).
- §3.2: `isRunning` is `false` once the effect's operation returns, it is replaced, or it is
  cancelled by `cancel(_:)` or teardown. Cancelling the task `send` returned cancels the effect, but
  `isRunning` reflects that only once the effect unwinds: the aggregate's `onCancel` runs off the
  isolation and cannot flag the core. The doc leaves out auto-cancel, which never reaches an
  identified effect (2b8694d).
- §3.3: an effect is registered in `tasks` by token before `Task.immediate` starts it, and its
  handle is attached once `Task.immediate` returns (TCA 2's attach shape), so `isRunning` holds in
  the effect's own preamble, an effect that finishes synchronously is not left tracked, and an
  effect cancelled or replaced during its preamble is cancelled when its handle arrives (95da2dc).
- §3.3: cancelled effects (auto-cancel, `cancel(_:)`, replacement) stay in `tasks`, flagged, until
  they finish unwinding, so `inFlightTasks` covers them and `TestHost.finish` waits for their
  `defer`; `isRunning` ignores flagged entries; `invalidate()` still drops everything (95da2dc).
- §3.3: `send` inside a `modify` body reports `Can't send <action> inside 'modify'; dropped`, and
  `perform` there reports `Can't perform an effect inside 'modify'; dropped`, instead of the
  combined reentrancy message; the root handle's `perform` reports instead of dropping silently
  when the core is gone. Behaviour is the same: reported and dropped (95da2dc).
- §3.3: effect tasks hold the core weakly (`didFinish` captures `[weak self]`, not the plan's
  `self.taskDidFinish(token)`), so the core lives exactly as long as its shell; after `ViewModel`
  deinit an unwinding effect's `effects.state` is reported and returns the last known value
  (2b8694d).
- §3.3: errors thrown by a cancelled effect are not reported; a live effect's errors still are
  (`catch _ where Task.isCancelled {}` ahead of the reporting `catch`). Cancellation can surface as
  an error other than `CancellationError` (`URLError(.cancelled)`, a dependency's own), and
  reporting it made a correctly cancelled effect look like a failure (7631c1f).
- §3.4: before OS 26 the aggregate `send` returns is a plain `Task`, because it is built in a
  nonisolated getter where `#isolation` is `nil`; cancelling it cancels the effects only once it
  starts, so the tests' synchronous-cancel checks are guarded by `#available(… 26 …)`, and the
  isolation probe's `.stop` cancels through an `@EffectID` key from `interact`, which is
  synchronous on every OS (307b242).
- §4.1: there is no `Never: Interactor` conformance; the primitives keep
  `var body: some Interactor<…> { self }` (95da2dc).
- §5.3: `DefaultIsolation` is an internal file-scope actor in
  `Internal/Concurrency/DefaultIsolation.swift`, shared by `ActorModel` and `TestModel`, not a
  `private actor` in a shell's file (95da2dc, c4a4fbb).
- §5.3: `ActorModel`'s doc comment omits "Child models created later share this isolation.":
  `ActorModel` has no scoping or child-model API (c4a4fbb).
- §5.4/§5.5/§5.6: what is still pending at deinit is reported as a warning that cannot fail a test
  and cannot be asserted: an `isolated deinit` runs without the test's task-locals, so Swift Testing
  records it unattributed at the line that created the model, and through IssueReporting's XCTest
  path without its message text. Both shells document ending exhaustive tests with `finish()`
  (supervisor decision A; 381bbc0, with the `.warning` severity made explicit in 86d60a1).
- §5.5/§5.6: the `isolated deinit` calls `host.invalidate()`, which reports the leftovers at the
  creation location and then calls `core.invalidate()`, rather than `host.core.invalidate()`
  (381bbc0).
- §5.4: leftovers are consumed once handled (TCA 2, supervisor-approved): an exhaustive `send` or
  `expect` reports what is pending, consumes it and proceeds (the old `TestViewModel` aborted the
  send); `finish` consumes what it reports; a failed `receive` reports the first pending action as
  unexpected (exhaustive) or that none arrived, then consumes everything pending (381bbc0).
- §5.4: interleaved commits fold leading entries only (TCA 2, supervisor-approved): `send` folds
  the modifications committed before the first nested action; `expect` reports the actions ahead of
  the modifications, then folds modifications up to the next action; `receive` folds everything
  before the match (reporting non-matching actions when exhaustive) plus the modifications right
  after it (381bbc0).
- §5.4: `.off` skips (supervisor-approved): `send` skips everything pending, `receive` everything
  before the match, `expect` the leading actions, `finish` and deinit everything. With
  `showSkippedAssertions` each skip is a warning; under XCTest, IssueReporting turns warnings into
  failures (381bbc0). `showSkippedAssertions` defaults to `true`, so `.off()` warns on every skip
  (86d60a1).
- §5.4: `finish` and `skipInFlightEffects` wait on the signal and re-read `core.inFlightTasks`
  after every signal instead of awaiting the task handles, and `skipInFlightEffects` cancels the
  in-flight tasks again on every signal, because a cancelled effect can still send an action that
  starts more (381bbc0).
- §5.4: the signal stream is recreated whenever a wait exits with its task cancelled, because an
  `AsyncStream` ends for good once a waiting consumer is cancelled, also when the wait then leaves
  through a `return` (381bbc0, corrected as deviation 8 in 86d60a1).
- §5.4: a second concurrent wait on one model (`receive`, `finish` or `skipInFlightEffects`) is
  reported and returns without doing anything else, because an `AsyncStream` takes one waiter
  (381bbc0, corrected as deviation 9 in 86d60a1).
- §5.4: a wait cut short by cancelling the waiting task is reported as cancelled, not as a timeout
  (`…before the wait was cancelled`, `…when the wait was cancelled`) (764a3f1).
- §5.4: `TestHost.areStatesEqual` is optional, so asserting without any equality reports the
  missing-equality issue at every assertion; the core gets the feature's own equality, and
  assertions use the feature's, else the initializer's (381bbc0).
- §5.4: `TestHost.init` takes a generic feature (`F.State == State`, `F.Action == Action`) plus the
  fallback equality, exhaustivity, timeout and creation location, because `FeatureProtocol` has no
  primary associated types; the core's hooks capture the host weakly, not `unowned` (381bbc0).
- §5.4: `TestHost.receive(matching:description:…)` is `receive(matching:expectation:…)` with an
  internal `ReceiveExpectation<Action>`, so the `Equatable` overload's failures can diff the
  expected action against the received one (86d60a1).
- §5.4: `withReportedTestFailures` is removed; issues are reported by a synchronous, nonisolated
  `reportTestFailure(_:severity:at:)` that runs on the calling shell's isolation, in the test's
  task. The old "assertion closure made no changes" special case is gone: an `update` that changes
  nothing while the state changed reports the ordinary state-diff mismatch (381bbc0).
- §5.5: the `areStatesEqual:` initializers of `TestModel` and `TestViewModel` take the same
  defaulted `fileID:filePath:line:column:` as the other initializer (introduced in 381bbc0; found
  while writing the docs).
- §5.5: the search and timer examples run, in `TestModelExampleTests`, on a gate and on a tick
  stream instead of `clock.advance` right after `send` (see the §8 clock note), and `.stop` cancels
  the timer through an `@EffectID` key with `effects.cancel(_:)`: `.stop` is another action case,
  so it does not auto-cancel `.start`'s effect (764a3f1).
- §5.6: `TestViewModel`'s initializers take `exhaustivity:` and `timeout:` like `TestModel`'s, and
  both shells label the location parameter `filePath:` (381bbc0).
- §6: the parallelism row runs 500 cases, not 100 `TestModel`s: `@Test(arguments: 1...500)` per
  shell (764a3f1, with the `ActorModel` variant in c4a4fbb).
- §7: a cancelled effect's `modify` is committed (§3.1), while the old runtime dropped a cancelled
  effect's response action, so the Search effects call `Task.checkCancellation()` before writing a
  result a newer action superseded, and `forecastRequestNonce` is removed in favour of auto-cancel
  plus that check (f50e4cd). The Phase load has no such check: its only suspension is a sleep that
  throws on cancel, every load writes the same case, and the `.loading` guard turns a late commit
  into a no-op (f6b644a, explained in the source in 5a25b14).
- §7: the tickers' `.observe { AsyncStream(unfolding:) }` became a `while true` loop of
  `try await clock.sleep(for:)` and `try effects.modify(tick)`, not the row's `for await`: a timer
  needs no stream, and the loop must not sleep with `try?`, which spins after a cancel because the
  clocks throw at once (de084e2, f6b644a).
- §7: `await task.finish()` maps to `await task?.value`, but inside a view's `.task` that does not
  stop the effect when the view goes away, so the Phase and TimerLeak views forward the `.task`'s
  cancellation with `withTaskCancellationHandler { await t?.value } onCancel: { t?.cancel() }`
  (f6b644a).
- §7: an action the interactor ignores still auto-cancels its case's anonymous effects
  (`Core.send` cancels after every `interact`). The Todos sort therefore runs as
  `perform(id: autoSort)` with `@EffectID var autoSort`, so an ignored toggle leaves it alone
  (b64efc6), while TimerLeak drops its `isRunning` guard instead, because the view's `.task` now
  owns and cancels the ticker and re-sending `.start` replaces it (f6b644a).
- §8 clock: no test advances a `TestClock` after a send. `TestClock.sleep` is `@concurrent`, so the
  effect registers its sleeper on the global executor while `advance` only mega-yields before it
  scans; under load 3 to 7 of 30 runs hung. Phase 1 ends sleeps by cancelling them and asserts that
  the sleep variant's 99 cancelled decrements are lost (the count stays 100) instead of the
  spike's 99 (2b8694d). From Phase 2 on, the owner's clock decision C applies: time is a test-local
  gate clock that the test waits on for the sleep's registration before it moves time, with no
  gate clock in the library (764a3f1, d3bc19f, f50e4cd, f6b644a).
- §8 isolation regression: the `TestModel` and `ActorModel` parts assert through the model actor's
  `preconditionIsolated()`, reached through a weak `any Actor` reference (`ActorShellReference`),
  not `core.isolation.assertIsolated()` through `@testable`: the host and the core are private, and
  the model's executor is the core's `DefaultIsolation` (764a3f1, c4a4fbb).
- §8, §10 negative compile checks: `MAINACTOR_INTERACTOR_TO_TESTMODEL` matches the note
  `sending main actor-isolated value of non-Sendable type 'Feature<CounterAction, CounterState>' to actor-isolated initializer 'init(initialState:feature:…`,
  not `… 'interactor' …`: `TestModel.init` takes `feature:`, so the compiler names the `Feature`
  value (the plan's text was spike B12's, whose model took the interactor). It is the note of a
  `sending … risks causing data races` error, so the SIL lane prints LLVM-style diagnostics and
  matches error and note lines (764a3f1).
- §8 test infrastructure: deinit leftover reports are not asserted (decision A), and at `expect`
  the pending modifications are folded, so an undescribed modification shows as the `expect`'s
  state diff; the leftover report at `expect` is for actions (764a3f1). Waits that must overlap or
  be cancelled start their waiter with `Task.immediate` and are ordered by a call on the model; the
  two old `skipInFlightEffects` tests are one; the port of
  `finishReportsBufferedReceivesProducedWhileWaiting` asserts the state instead of a trailing
  `receive`, because `finish` consumes what it reports (764a3f1).
- §8 parallelism: a parameterized test cannot time its own cases, so the `@Test(arguments: 1...500)`
  tests of each shell share a timing record, and the case that completes it compares the wall
  times. The comparison runs only when all the variants run, and it is skipped for a shell whose
  cases ran one at a time (`swift test --no-parallel`) or on one core. A block-overlap assertion
  shows that the actor shells' effects ran in parallel, with `ViewModel` as the control (764a3f1,
  c4a4fbb).
- §8, §9 Phase 4: the Debounce tests' cancellation log is exact for sends spaced by a registration
  wait; truly back-to-back sends are asserted by outcome (one live sleep, one run), because a sleep
  cancelled before it registers never logs synchronously (d3bc19f, f50e4cd).
- §9 Phase 1: `Interactors.Debounce` landed in Phase 1, because the build needed it; its tests
  stayed in Phase 4 (95da2dc).
- §9 Phase 1: the old test shells in `Testing/TestViewModel/` (`TestViewModel`, `TestEventTask`,
  `InFlightEffectRecord`, `RootSendOrigin`, `PendingReceive`) were deleted in Phase 1, not Phase 2,
  because they depended on the deleted machinery; Phase 2 rebuilt the test shells over `TestHost`
  (95da2dc).
- §9 Phase 1: the `Tests/LatticeTests` port is its own step, so 95da2dc does not build the test
  target (95da2dc). The port excluded the tests that need the test shells in `Package.swift`
  (2b8694d); Phase 2 restored all but `Interactors+DebounceTests.swift` (764a3f1), which step 4A
  restored, removing the `exclude:` parameter (d3bc19f).
- §9 Phase 3: the tests are three suites in `PresentationTests/ActorModelTests/`, plus the
  parallelism variant in `IsolationTests/ParallelismTests.swift` (c4a4fbb). 12 of the 24 §6 rows
  have no `ActorModel` test: they are core behaviour the shell neither adds to nor changes, covered
  under `ViewModel` and `TestModel`; the row-to-test map is in the commit body (8c711cc).
- §9 Phase 4: the Debounce and example tests use the gate clock instead of `TestClock`
  (decision C; f50e4cd, f6b644a). The observation tests (FineGrained, ScopedComposition and Phase's
  render-boundary tests) stay on `ViewModel`; the behaviour tests are on `TestModel` (f6b644a).
  The ports go beyond 1:1: new Search, Todos, Debounce, Phase and TimerLeak tests, and the stale
  `noneEmissionsPassThrough` and `allActionsProcessedImmediately` became
  `childWithoutEffectsPassesThrough` (f50e4cd, f6b644a).
- §9 Phase 5: besides the files listed, the specs that named the removed runtime were updated too
  (`feature-state.md`, `fine-grained-observation.md`, `scoped-view-composition.md`,
  `enum-case-scoping.md`, `observable-state-identity-preserving-merge.md`, `macros.md`), and the
  `ActorModel` docs are a section of `view-model.md` (d24339e).
- §10: the example packages keep `NonisolatedNonsendingByDefault` off, as consumers would, and
  mark their dependencies' async methods `nonisolated(nonsending)` (f50e4cd).
- Outside the plan: the example test-support types shared between the test and the model's
  executor (`GateClock`, `CallLog`, `Gate`, the existing `ChangeProbe`) are locked
  `@unchecked Sendable` classes, because `Clock` refines `Sendable` and the others cross from the
  model's executor to the test; the feature layer has no `Sendable` (f50e4cd). A pre-existing
  SwiftUI `@Entry` warning in `ScopedCompositionView.swift` is left as it was (f6b644a).

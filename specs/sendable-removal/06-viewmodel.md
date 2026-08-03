# 06 — ViewModel as a Thin Host over the Core

Workstream 6 of the Sendable-removal rework (see `README.md` in this directory). Depends on
02 (core runtime), 03 (`Effects` handle), and 04 (`interact` signature / `AnyInteractor`
rewrite), and lands **with** 10 (`@FeatureState`/`@Domain` — it defines the projection,
registrar, and `_commit` diff this host wires up). Workstream 7 (testing) depends on this
plan's `EventTask` semantics.

## Overview

Today `ViewModel` *is* the runtime: it owns the action buffer, the drain loop, root-scope
bookkeeping, effect spawning, and two locked registries just so `deinit` can cancel work. After
plan 02 lands, all of that lives in the core — and after plan 05, the ViewState layer the
ViewModel hosted (reducer, working copy, `@ObservableState` observation) is deleted outright,
not preserved. `ViewModel` shrinks to exactly four jobs:

1. Own the core and forward `sendViewEvent(_:)` to `core.send`.
2. Own the `FeatureStateRegistrar` side table and install the generated projection diff as
   the core's commit hook (installed at `core.mount(onCommit:)` →
   `registrar.commit { State._commit }`; plan 05).
3. Expose the view read surface as a `@dynamicMemberLookup` projection over the core's
   committed state.
4. Wrap the composite effect task returned by `core.send` in the unchanged `EventTask` public
   type.

| Item | Change |
|------|--------|
| `ViewModel.swift` | Rewritten as a thin host: ~440 lines → well under 100. All buffering/scope/registry machinery deleted; the reduce/commit machinery — `commitViewState`, the working-copy/exclusivity-trap dance, `_viewState`, `areStatesEqual`, the reducer property, the `ObservationRegistrar` — deleted with the ViewState layer (plan 05), not moved. `sendViewEvent(_:) -> EventTask` signature **unchanged** (pinned contract). |
| `EventTask.swift` | Public shape unchanged (`Sendable` struct wrapping `Task<Void, Never>?`). Quiescence redefined as "the effect tasks this send launched directly", awaited through the composite task `core.send` returns; task-based instead of 1 ms polling. Doc-only diff. |
| `ScopedViewModel.swift` | Re-shaped: the scope exposes the **child's projection** instead of a `ViewState` getter chain; `_send` embedding unchanged. `ChildAction: Sendable` (and `GrandAction`/`CaseAction`/child-action constraints on every `scope`/`scopeIfActive` overload) dropped. Effect scoping lives in the core, so the view-layer scope stays a stateless lens. |
| `ViewModelBinding.swift` | Read key path retargets from `KeyPath<ViewState, Value>` to `KeyPath<State._ViewMembers, Value>` (plan 05 §9); shape and call sites otherwise unchanged. No `Sendable` constraints existed here. |
| `Feature.swift` | Narrows to **interactor + state type**: `viewStateReducer`, `makeInitialViewState`, and `areStatesEqual` leave the bundle — their layer is deleted (plan 05 §10). All `Sendable` constraints dropped with the old where-clauses. |
| `ViewStateReducer.swift` / `BuildViewState.swift` | **Deleted, not relaxed.** The whole `ViewStateReducer` layer goes per the pinned README contract; see §6. |
| `ViewModel` deinit | Deleted. Cancellation moves to the core storage's plain `deinit` (see §Deinit story). |

### Core interface consumed (contract on plan 02)

`02-core-runtime.md` owns the type; this plan pins the surface `ViewModel` needs from it.
Names below are illustrative; semantics are binding:

```swift
@MainActor
final class Core<DomainState, Action> {  // non-Sendable; carries the interactor tree + GraphPaths
    var state: DomainState { get }

    /// Installs the host contract: the routing closure plus the host's observation hooks.
    /// `onCommit` is the projection-diff stage of the commit funnel — the generated `_commit`
    /// call — invoked after every mutation commit (update phase and `modify` alike) with the
    /// pre/post state, *after* transition detection has cancelled dismounted path buckets.
    func mount(
        interact: @escaping (inout DomainState, Action) -> Void,
        onCommit: ((_ previous: DomainState, _ current: DomainState) -> Void)?,
        onEffectLaunched: ((TaskKey, Task<Void, Never>) -> Void)?
    )

    init(initialState: DomainState, interactor: AnyInteractor<DomainState, Action>)

    /// Synchronous root send. Runs the update phase (and its commit) to completion before
    /// returning.
    /// Returns a composite task over the effects the update launched directly — awaiting it
    /// awaits them all, cancelling it cancels them — or `nil` iff the update launched no
    /// effects.
    func send(_ action: Action) -> Task<Void, Never>?
}
```

Invariants this plan relies on (enforced in plans 02/03, verified by tests here):

- **Weak capture invariant**: effect tasks and `Effects` handles never strongly retain the
  core. The composite task returned by `send` holds only effect `Task` handles, never the core.
  This is what makes the deinit story work without registries.
- Core storage `deinit` cancels every bucket; outstanding composite send tasks complete as the
  cancelled effects wind down.

## File-by-file changes

### 1. `Sources/Lattice/Presentation/ViewModel/ViewModel.swift` — rewritten

Everything besides forwarding is deleted, including the pieces an earlier draft of this plan
preserved: `commitViewState`, the working-copy/exclusivity-trap dance, `_viewState`, the
`areStatesEqual` gate, the reducer property, and the `ObservationRegistrar`. None of it has a
replacement inside `ViewModel` — observation is the registrar side table plus the generated
diff, and nothing fires at `willSet` (plan 05). What remains, in shape:

```swift
@MainActor
@dynamicMemberLookup
public final class ViewModel<State: FeatureStateProtocol, Action> {
    private let core: LatticeCore<State, Action>
    private let registrar = FeatureStateRegistrar()

    public init(initialState: State, interactor: some Interactor<State, Action>) {
        core = LatticeCore(initialState: initialState, isolation: MainActor.shared)
        // the interactor tree walk builds the routing closure; mount installs it together with
        // the projection-diff commit hook
        core.mount(
            interact: { [unowned core] state, action in
                // the interactor tree walk routes the action from the root path
                interactorTree.route(state: &state, action: action, core: core, path: GraphPath())
            },
            onCommit: { [registrar] old, new in
                // the generated diff fires the registrar for members whose value/output
                // changed; the batch pokes each signal once and bubbles to coarse slots
                registrar.commit {
                    State._commit(old: old, new: new, registrar: registrar, key: ProjectionKey())
                }
            }
        )
    }

    private var projection: FeatureProjection<State> {
        FeatureProjection(
            read: { [core] in core.currentState },
            registrar: registrar,
            key: ProjectionKey()
        )
    }

    // Root dynamic-member lookups mirror FeatureProjection's overload set
    // (leaf / child / optional child / collection) and delegate to it.
    @_disfavoredOverload
    public subscript<Value: Equatable>(
        dynamicMember member: KeyPath<State._ViewMembers, Value>
    ) -> Value { projection[dynamicMember: member] }

    @discardableResult
    public func sendViewEvent(_ event: Action) -> EventTask {
        EventTask(rawValue: (try? core.send(event)) ?? nil)
    }
}
```

Plan 05 §11.1 owns the normative sketch (the full `dynamicMember` overload set, projection
semantics, registrar); this plan owns the file. Notes:

- `DequeModule` / `OrderedCollections` imports drop out of this file, and so does
  `Observation`: the ViewModel no longer touches the observation framework directly — the
  registrar's signal objects do, in `Sources/Lattice/FeatureState/`. Whether the collections
  package dependency itself becomes removable is a workstream 9 pruning question (the core may
  still use ordered collections internally).
- The `_ViewModel` shim protocol (`ViewState: ObservableState`) and the `viewState` accessor
  are deleted; views read members through the projection, and `ViewModelBinding` retargets its
  key paths accordingly (§4).
- There is **no whole-state equality gate** and no `areStatesEqual` init parameters: gating is
  per member, inside the generated `_commit` (plan 05 §5). The `DomainState == ViewState`
  convenience inits vanish with the distinction itself.
- `ViewModel`'s generic surface changes from `ViewModel<F: FeatureProtocol>` to
  `ViewModel<State, Action>` with a direct `init(initialState:interactor:)`; the narrowed
  `Feature` (§5) keeps a `init(initialState:feature:)` convenience.
- `domainState` is no longer stored on `ViewModel`; the core owns it (`core.state` is available
  internally if a future API needs a read).
- There is **no `deinit`**. See §Deinit story.

### 2. `Sources/Lattice/Presentation/ViewModel/EventTask.swift` — doc-only diff

The public shape is pinned and unchanged: `public struct EventTask: Sendable` wrapping
`Task<Void, Never>?`, with `cancel()`, `finish()`, `isCancelled`, `hasEffects`. Only the
doc comments change to describe the new coverage semantics:

```diff
--- a/Sources/Lattice/Presentation/ViewModel/EventTask.swift
+++ b/Sources/Lattice/Presentation/ViewModel/EventTask.swift
@@
-/// A handle to the root send scope started by a single `sendViewEvent` call.
+/// A handle to the effects launched by a single `sendViewEvent` call.
 ///
-/// Use `EventTask` to await transitive effect completion or cancel the in-flight work owned by that send.
+/// Use `EventTask` to await effect completion or cancel the in-flight work launched by
+/// that send.
 ///
-/// `EventTask` tracks a root send scope, not only the first generation of tasks created by an
-/// action. If an effect emits more actions and those actions start more work, that downstream work
-/// remains part of the same scope.
+/// `EventTask` covers the effects the send launched directly. If an effect re-enters the
+/// interactor with `effectState.send`, the work that update launches is an independent unit with
+/// its own task (returned by `effectState.send`); it does not extend this handle. Direct state
+/// mutation via `effectState.modify` commits synchronously and spawns no work.
```

(Remaining doc examples — `.refreshable`, `.task`, fire-and-forget — unchanged.)

#### EventTask quiescence semantics (normative)

**Coverage.** `EventTask` wraps the composite task returned by `core.send`: one task that
awaits every effect launched by `Effects.perform` during the update phase of the sent event.
Nothing else ever joins it. A re-entrant `effectState.send` from one of those effects is a fresh
`core.send` with its own composite task — an independent unit the original `EventTask` neither
awaits nor cancels.

**`finish()`** awaits the composite task, i.e. every directly launched effect. Effects that are
cancelled along the way (auto-replacement by a later send at the same `(path, location)`,
case-exit transition detection, host teardown) complete as they wind down, so `finish()` always
returns — awaiting a cancelled or finished task is a plain, prompt await. No continuations are
parked anywhere; this replaces the deleted `RootScopeTasks` 1 ms polling loop.

**`cancel()`** cancels the composite task, which propagates cancellation to each directly
launched effect task. Effects observe it cooperatively (`modify` throws, `Task.isCancelled`);
`finish()` then returns once they have wound down.

**`hasEffects`** is `rawValue != nil`. `core.send` returns `nil` iff the update launched no
effects, so a no-effect send yields `hasEffects == false` and an immediate `finish()`. An
effect that completes synchronously still counts as launched: its `EventTask` is non-nil and
`finish()` returns immediately.

**Host teardown.** Core storage `deinit`/dismount cancels every bucket; composite tasks
complete as their effects wind down, so a parked `finish()` returns rather than hanging. The
composite task holds effect `Task` handles — never the core — so a long-lived `EventTask` held
by a view does not extend the `ViewModel`'s lifetime.

### 3. `Sources/Lattice/Presentation/ViewModel/ScopedViewModel.swift` — child projection + Sendable drops

`ScopedViewModel` stays a stateless value lens, but its read half changes with the ViewState
layer's deletion: instead of chaining the parent's `@ObservableState` getter path, the scope
exposes the **child's projection** — the same `FeatureProjection<Child>` the parent's
`dynamicMember` subscript returns for a nested `@FeatureState` member (plan 05 §3.5). Access
registration and per-member invalidation therefore work identically through a scope and
through the root. `_send` is unchanged in role: embed child actions into the parent action,
forward to `sendViewEvent`. Shape:

```swift
@dynamicMemberLookup
@MainActor
public struct ScopedViewModel<Child: FeatureStateProtocol, ChildAction> {
    let projection: () -> FeatureProjection<Child>   // chains through the parent's projection
    let send: (ChildAction) -> EventTask

    // dynamic-member overload set mirrors FeatureProjection's
    // (leaf / child / optional child / collection), delegating to projection().
}
```

The `scope`/`scopeIfActive` overloads re-key from `KeyPath<ViewState, ChildState>` /
`CaseKeyPath<ViewState, Child>` to the projection namespace
(`KeyPath<Parent._ViewMembers, Child>`; case scoping rides plan 05 §4.2's generated enum case
accessors), and every `ChildState: ObservableState` / `ChildAction: Sendable`-style constraint
(`GrandAction`/`CaseAction` included) is dropped — `ObservableState` no longer exists,
`FeatureStateProtocol` takes its structural place. The scope does **not** grow an `Effects`
reference: effect scoping — child task buckets, cancellation on case exit, dropped `modify`
after dismount — is entirely the core's job via `When` nodes and `GraphPath` prefixes (plans
02/03/04).

Two doc updates in the same file:

- `scopeIfActive` already documents "a send can arrive after the case has deactivated; the
  interactor should drop actions that no longer apply". Strengthen it with the now-*guaranteed*
  runtime half of that contract: `When` drops the action when the case is inactive, and the
  core has already cancelled the child's path-prefix task bucket at case exit; a child effect's
  late `modify` is dropped silently (pinned scoping contract). The consumer-facing advice is
  unchanged.
- The "scopes strongly retain their parent" warning stays valid word-for-word: the
  projection/`send` closures capture the parent, and effect cancellation still runs at parent
  teardown (now via core storage `deinit` instead of `ViewModel.deinit`).

### 4. `Sources/Lattice/Presentation/ViewModel/ViewModelBinding.swift` — key-path retarget only

No `Sendable` constraints, no `Emission`/runtime references. Per plan 05 §9, the binding's
read key path retargets from `KeyPath<ViewState, Value>` to
`KeyPath<State._ViewMembers, Value>`: reads route through the projection (registering access
like any read), writes still send the event through the interactor. `_ViewModelBinding`,
`_ViewModelCaseBinding`, `_ViewModelCaseMemberBinding`, and the `Bindable`/`Binding`
subscripts keep their shape and call sites against the stable `sendViewEvent` signature.

### 5. `Sources/Lattice/Presentation/Feature/Feature.swift` — narrowed to interactor + state type

The bundling contract changes: `viewStateReducer`, `makeInitialViewState`, and
`areStatesEqual` leave the bundle — the reducer type and equality strategies are deleted with
their layer (plan 05 §10), and there is no `ViewState` associatedtype left to produce.
`Feature` survives as a slim convenience pairing a state type with an erased interactor
(this is the call plan 05 §10 delegates here); `ViewModel` can equally be built directly via
`init(initialState:interactor:)`.

```swift
public protocol FeatureProtocol {
    associatedtype State: FeatureStateProtocol
    associatedtype Action

    var interactor: AnyInteractor<State, Action> { get }
}

public struct Feature<State: FeatureStateProtocol, Action>: FeatureProtocol {
    public let interactor: AnyInteractor<State, Action>

    public init<I: Interactor>(interactor: I)
    where I.DomainState == State, I.Action == Action {
        self.interactor = interactor.eraseToAnyInteractor()
    }
}
```

The old `Action: Sendable` / `DomainState: Sendable` / `I: Interactor & Sendable` /
`R: ViewStateReducer & Sendable` constraints all disappear with the members that carried them
— the reducer inits and the `DomainState == ViewState` special-case inits are **deleted, not
relaxed**. The stored `AnyInteractor` spelling is unchanged even though its innards are
rewritten by plan 04 (new `interact(state:action:effects:)` shape, erasure no longer
`Sendable`-gated).

### 6. `Sources/Lattice/Presentation/ViewStateReducer/` — deleted

An earlier draft of this plan relaxed the `AnyViewStateReducer` erasure's `Sendable`
constraints; the pinned README contract now deletes the layer outright, so there is nothing to
relax. Removed with plan 05 §10's deletion list (which executes when this plan flips the
ViewModel host):

- `ViewStateReducer.swift`: the protocol, the result-builder body, `AnyViewStateReducer`,
  `eraseToAnyReducer()`.
- `BuildViewState.swift`: the whole type.
- The `@ViewStateReducer` macro's `initialViewState(for:)` / `DefaultValueProvider` validation
  loses its target; the macro deletion itself is plan 08's line item (fed by plan 05 §11.3).
- The `@ObservableState` macro and `ObservationStateRegistrar`/`_$id` copy-identity machinery
  go in the same sweep (plan 05 §10); nothing in the presentation layer references
  `ObservableState` afterwards (§Acceptance gates).

### 7. Deletions from `Sources/Lattice/Internal/Execution/` — coordination note

After this rewrite, the production side no longer references `BufferedAction`, `ActionSource`,
`ActionTransition`, `RootScopeState`, `RootScopeTasks`, `EffectTaskRegistry`,
`EffectCancellationRegistry`, or `EmissionExecution`. `TestViewModel` still does until
workstream 7 rewrites it — physical file deletion is sequenced with plan 07 (or already done by
plans 02/04 if the old test pipeline is removed earlier in the PR series; either way, the gate
below only asserts the **Presentation** layer is clean). `SendScopeID` is deleted outright —
nothing replaces it; `EventTask` wraps the composite task `core.send` returns (plan 02).

## Deinit story

**`ViewModel` has no `deinit`.** The teardown chain:

1. `ViewModel` is the unique strong owner of the core. Nothing else retains it strongly: effect
   tasks capture only the `Effects` handle, which holds the core **weakly** (the weak-capture
   invariant, plans 02/03); `EventTask` holds only effect `Task` handles.
2. When the last `ViewModel` reference drops, the core — and its task-storage object — deinit
   synchronously.
3. The storage's **plain, nonisolated `deinit`** walks `[GraphPath: [Location: Task]]` and
   cancels every task; outstanding composite send tasks complete as those effects wind down.
   This is safe without locks or actors: `deinit` has exclusive access to the dictionaries (no
   other reference exists; weak refs already resolve `nil`), `Task<Void, Never>` handles are
   `Sendable`, and `Task.cancel()` is nonisolated and
   thread-safe. This mirrors TCA26's `Storage.deinit` → `dismount()`
   (`Internal/Core.swift:846-860`), which cancels `tasks` the same way.
4. Cancelled effects that are already mid-flight observe cancellation cooperatively; a late
   `effectState.modify` finds the weak core `nil` and throws `CancellationError` (pinned
   post-dismount contract). No mutation is lost-then-half-applied; it simply never happens.

This deletes the entire reason `EffectTaskRegistry` / `EffectCancellationRegistry` existed —
locked mirrors reachable from a nonisolated `deinit` — and with them the last
`@unchecked Sendable` in the presentation layer.

Not chosen: `isolated deinit` (SE-0371, TCA26 `Store.swift:46`). Its runtime support is
iOS 18/macOS 15+, above our iOS 17 floor. When the floor moves, the storage `deinit` can become
an `isolated deinit` on the core for stricter ordering guarantees; the observable semantics
(all buckets cancelled at host teardown) are the same, so nothing in this plan blocks that.

## Behavioral notes

### Reentrancy (vs. today's `isSending` + `Deque`)

- **Interactor-driven reentrancy is gone by construction.** `interact` is synchronous and
  returns `Void`; `EffectState.send`/`modify` are effect-phase-only (loud preconditions, plan 02).
  The old case "interactor emits `.action` while draining" no longer exists.
- **View-driven reentrancy still exists** and must keep working: `_commit` pokes registrar
  signals as its commit batch closes inside the funnel, which notifies synchronous observers
  (`withObservationTracking` onChange), and an observer can call `sendViewEvent` before the
  current commit returns — the case `ViewModelReentrancyTests` exercises today via buffering.
  Per plan 02, the funnel runs the host hook with value copies (never with the domain state
  `inout`-open), so such a re-entrant `sendViewEvent` executes as a **plain synchronous
  recursion**: its own full update + commit + effect launch, returning its own `EventTask` for
  the effects it launched. The old drain-loop deferral is gone; unbounded synchronous recursion
  is an app bug (plan 02 §10). Non-reentrant sends execute fully synchronously — state is
  committed and the registrar fired before `sendViewEvent` returns, exactly as today for
  `.sent` actions.
- **The exclusivity trap is gone by construction.** Nothing fires at `willSet`, and no formal
  access on observable storage is ever open while observers run: `_commit` diffs two value
  copies and pokes signals in the registrar side table, which is separate from the state. A
  synchronous observer may read the projection (the core's committed state) mid-commit
  freely; there is no working copy to maintain and no exclusivity dance to preserve.

### Buffering vs. current `BufferedAction` behavior

| Today | After |
|-------|-------|
| Effect completions produce `.emitted` actions, buffered in a `Deque`, each re-running the interactor. | Deleted. Effects re-enter via `modify` (synchronous direct commit) or optional `effectState.send` (synchronous full update). No queue between an effect and its state mutation. |
| Emitted actions inherit `rootScopeID` → `EventTask` transitivity via `bufferedActionCount + inFlightEffectIDs`. | No transitivity: `EventTask` wraps the composite task over the send's directly launched effects. Re-entrant `effectState.send` (and re-entrant view sends) are independent units with their own returned tasks. |
| `.emitted` commits **always** reduce ViewState (change assumed); `.sent` commits gate on `areStatesEqual`. | Both gates deleted with their layer. Every commit runs `_commit`, which gates **per member**: only members whose value/output changed fire the registrar (plan 05 §5). An effect `modify` producing an equal state fires nothing; there is no whole-state equality strategy to configure. |
| `.action` emissions ordered after the current interact within one drain pass. | No `.action`. Same-update follow-ups become straight-line code inside `interact` (migration handled in plan 04's rewrite + workstream 9 docs). |
| `EventTask.finish()` polls quiescence every 1 ms. | A structured await on the composite effect task. `finish()` latency drops; tests that accidentally relied on the polling grace window must await properly (they should already). |

### Ordering guarantee (documented in the rewritten `ViewModel` doc comment)

For a non-reentrant `sendViewEvent`: update phase runs → every synchronous mutation is
committed through the funnel (transition detection → projection diff: `_commit` fires the
registrar for changed members) → tasks launch in-domain (they cannot preempt the update; their
first suspension point is after `send` returns) → `sendViewEvent` returns the `EventTask`.
Effects' later `modify` calls commit through the same funnel one at a time, each firing exactly
the projection keys that commit changed.

## Test plan

All under `Tests/LatticeTests/PresentationTests/` unless noted. Fixture state types move to
`@FeatureState` and fixture interactors to the new `interact(state:action:effects:)` shape
(coordinated with plans 04/05); several fixtures should deliberately use **non-Sendable**
state/action types to lock in the point of the rework.

| File | Action |
|------|--------|
| `ViewModelTests.swift` | Rewrite fixtures on `@FeatureState` types; keep coverage in spirit: send → domain mutation → projected members reflect it; a commit that changes nothing fires no registrar keys (per-member gate replacing the old equality-skip test); `dynamicMember` reads through the projection; `modify` from an effect updates the projection (new); non-Sendable `DomainState`/`Action` compile-and-run fixture (new). Which-keys-fired granularity assertions live in plan 05 §11.2's `RecordingRegistrar` suites, not here. |
| `EventTaskTests.swift` | Rewrite around the new semantics: (1) no-`perform` send → `hasEffects == false`, immediate `finish()`; (2) single `perform` → `finish()` awaits it; (3) **direct-only coverage**: effect calls `effectState.send`, whose update `perform`s again → the original `finish()` returns without awaiting the second generation, and the task returned by `effectState.send` awaits it; (4) `modify` does not extend the handle; (5) `cancel()` cancels the send's in-flight effect tasks and `finish()` returns after wind-down; (6) auto-replacement across two sends: first `EventTask` finishes at replaced-task wind-down, second owns the replacement; (7) case-exit commit cancels the effects → `finish()` returns without effect completion; (8) reentrant send from a synchronous observer runs recursively and returns its own live `EventTask`; (9) an effect that completes synchronously → `hasEffects == true`, `finish()` returns immediately. Use `TestClock` for deterministic suspension. |
| `ViewModelReentrancyTests.swift` | The exclusivity-trap test is **deleted** — the trap it guarded (a formal access on `_viewState` open during reduce) cannot exist without the working copy and `willSet` firing. Keep the suite for its remaining purpose: synchronous observer reads the projection mid-commit → correct committed values, no trap; synchronous observer calls `sendViewEvent` mid-commit → runs as a recursive send, both states correct, no reentrancy crash. |
| `ScopedViewModelTests.swift`, `EnumCaseScopingTests.swift`, `ViewModelBindingTests.swift`, `FeatureViewModelTests.swift` | Re-fixture onto projections: assertion targets rename from ViewState members to projected members; case scoping rides the generated case accessors. Add one non-Sendable `ChildAction` scope fixture to `ScopedViewModelTests`. |
| `FineGrainedObservationTests.swift`, `ViewModelObservationTests.swift`, `ObservableStateAssignmentTests.swift` | Delete here — the `@ObservableState` observation dance they pin no longer exists. Their intent (per-member invalidation granularity) is re-covered by plan 05's registrar/projection suites (§11.2 `RecordingRegistrar`, §12 gates). |
| `ViewModelAppendTests.swift` | Delete (`.append` emission composition no longer exists; plan 04 owns the concept's removal, this file goes with it). |
| `ViewModelDeinitTests.swift` (new) | (1) Release a `ViewModel` with an in-flight effect → effect observes cancellation (confirmation via a continuation flipped in the effect's cancellation path); (2) `finish()` parked on an `EventTask` resumes when the `ViewModel` is released (cancelled effects wind down and the composite task completes); (3) an outstanding `EventTask` held after release does not keep the core alive (weak assertion on the core via a test hook, or absence-of-leak via `deinit`-side-effect flag); (4) post-teardown `modify` throws `CancellationError` (shared with plan 03's tests). |

`TestViewModel`-side coverage is workstream 7; nothing here touches `Sources/Lattice/Testing`.

## Acceptance gates

```bash
# Builds and the presentation-layer suites pass
swift build --build-tests
swift test --filter LatticeTests

# Pinned view-layer API shape intact
grep -q "public func sendViewEvent(_ event: Action) -> EventTask" \
  Sources/Lattice/Presentation/ViewModel/ViewModel.swift
grep -q "public struct EventTask: Sendable" \
  Sources/Lattice/Presentation/ViewModel/EventTask.swift

# Old machinery fully evicted from the presentation layer
! grep -rn "BufferedAction\|RootScope\|EffectTaskRegistry\|EffectCancellationRegistry\|EmissionExecution\|Emission<\|isSending\|DequeModule" \
  Sources/Lattice/Presentation/

# ViewState layer fully deleted from the presentation layer
! test -d Sources/Lattice/Presentation/ViewStateReducer
! grep -rn "ViewStateReducer\|BuildViewState\|ObservableState\|areStatesEqual\|_\$id\|ObservationRegistrar" \
  Sources/Lattice/Presentation/

# ViewModel hosts the registrar and installs the generated diff
grep -q "FeatureStateRegistrar" Sources/Lattice/Presentation/ViewModel/ViewModel.swift
grep -q "_commit(old:" Sources/Lattice/Presentation/ViewModel/ViewModel.swift

# ViewModel is deinit-free (teardown lives in the core storage)
! grep -n "deinit" Sources/Lattice/Presentation/ViewModel/ViewModel.swift

# Sendable constraints gone from the feature/view layer
! grep -n "Sendable" Sources/Lattice/Presentation/Feature/Feature.swift
! grep -En "(Child|Grand|Case)Action: Sendable" \
  Sources/Lattice/Presentation/ViewModel/ScopedViewModel.swift
```

Do **not** run `swift-format` manually (pre-push hook owns it, per AGENTS.md).

## Risks

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Weak-capture invariant broken somewhere (an effect or wrapper strongly retains the core) → core never deinits, buckets never cancel at teardown. | **High** | `ViewModelDeinitTests` (1)–(3) fail loudly on any strong capture; invariant is also stated in plans 02/03 where the captures are written. |
| An effect task that never completes after cancellation (uncooperative body with no suspension points in a loop) → `finish()` hangs. | Medium | Inherent to cooperative cancellation, not new; the composite-task await has no bookkeeping of its own to get wrong (no continuations to leak). `EventTaskTests` (5)–(8) cover the cancellation interleavings. |
| Consumers with `where Action: Sendable`-style clauses over `Feature`/`ScopedViewModel` generics break at compile time. | Medium | Deliberate API break of the rework; workstream 9 migration guide. Constraint *removal* never breaks conformances, only redundant clauses. |
| `ScopedViewModel` case-scope snapshot fallback (serves the creation-time payload for one transitional render after case exit) now coexists with core-side task cancellation at the same commit — a stale render could show payload whose effects are already dead. | Low | Same one-render window exists today; effects were never observable through the snapshot. Doc note added in §3. |
| §5's `Feature` narrowing and §6's deletions cannot land ahead of plan 05's runtime types and plan 04's `AnyInteractor` relaxation, or the presentation layer won't compile in between. | Low | Sequencing note: §1/§5/§6 land in the same commit series as plan 05 §10's deletion flip, after 04; until then both layers compile side by side (plan 05 §1). |

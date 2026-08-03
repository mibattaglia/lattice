# Plan 10 — Dynamic Body Re-Evaluation (OPTIONAL / FUTURE)

> **⚠️ OPTIONAL / FUTURE WORKSTREAM — EXPLICITLY OUT OF SCOPE FOR THE 1.0 REWORK.**
>
> The README's decisions of record pin the 1.0 composition tree as **static, built once**, with
> "no dynamic body re-evaluation now; it is a *future* direction." This document is that future
> direction, written down while the substrate (plan 02 §11's seams) is fresh. Nothing here ships
> with plans 01–09, nothing here blocks them, and adopting this plan later requires amending the
> README contract first (§8 lists the exact renegotiation points). Treat every API sketch as a
> proposal to be re-validated against the shipped 1.0 surface at adoption time.

Reference implementation: TCA26 (`/Users/michaelbattaglia/Documents/pointfree/TCA26/Sources/
ComposableArchitecture2`) — `Internal/Core.swift` (observeForRemount :158–205, `Storage`
generation/mount/dismount :771–860, `enqueueDismount` :640–655, `ForEachCore`/
`ForEachElementCore` :1550–2000), `Feature.swift` (`_GraphPath`, `_GraphValue`,
`_GraphValueCacheKey`, `bodyLocation` caching, `_isIdentical`), `Features/Spawn.swift`
(`SpawnedCore`, ifLet/ifCaseLet/forEach reconciliation, version-box `touch()`, dismiss
handlers), `ValueObservation/ValueObservable.swift` + `ValueObservationTracked.swift`
(per-property observation with change strategies), `FeatureModifiers/OnMount.swift` /
`OnChange.swift` / `OnDismount.swift`, and `ComposableArchitecture2Macros/FeatureMacro.swift` +
`ValueObservableMacro.swift` (memberAttribute expansion applying `@ValueObservationTracked`).

---

## 1. Motivation — what the static tree cannot do

The 1.0 tree is evaluated once at `ViewModel` init. `GraphPath`s are computed once, presence
watchers are registered once, and `body` is required to be pure and structurally stable (plan 04
documents "an impure `body` silently strands tasks under the old branch tag" as a known,
accepted limitation). Presence-flip prefix cancellation (plan 02's commit funnel) covers the
single most common lifecycle need — kill a dismissed child's effects — but four capabilities are
structurally out of reach:

1. **State-dependent composition.** A `body` whose *shape* depends on domain state
   (`if state.isPremium { AnalyticsInteractor() }`) cannot exist: `body` never sees state, and
   `Interactors.Conditional` pins its branch at construction. Today the workaround is routing
   every action through one leaf that switches on state — losing composition entirely.
2. **Automatic mount/dismount lifecycle.** There is no "this subtree just came into existence /
   just left" event. `When` over a case path silently skips absent children and the funnel
   cancels tasks on exit, but nothing can *run code* at those boundaries — no "start observing
   the socket when the detail screen appears", no "flush the draft when it disappears". The 1.0
   idiom pushes this into explicit actions (`.onAppear` sent by the view), which couples domain
   lifecycle to view visibility — exactly the distinction TCA26's `onMount`/`onDismount` docs
   call out against `onAppear`/`task`.
3. **`forEach` over dynamic collections with per-element identity.** `MergeMany` is positional
   and static ("reordering the collection at runtime is unsupported", plan 04 §4). A list of N
   row features, each with its own effect buckets that die when *that row* is deleted — the
   `NavigationStack`/list-of-features shape — has no expression. Element identity must key the
   `GraphPath` (`.id(elementID)`), and elements must mount/dismount as the collection changes.
4. **`onMount` / `onDismount` / `onChange` modifiers.** Declarative reactions to state
   transitions ("when `query` changes, kick a search"; "when this feature mounts, warm the
   cache") without a dedicated action case per reaction. `onChange` in particular subsumes a
   whole class of "send an action so the interactor can notice a change it just made" patterns.

What dynamic body does **not** buy Lattice: it does not replace `interact`, it does not change
the effect model (imperative `perform`/`modify`, unchanged), and it does not change the
view projection pipeline (plan 05's diff-at-commit). It changes *when the composition tree is
(re)computed* and adds lifecycle events at tree edits.

### Non-goals (deliberate)

- **No `SpawnedCore` / independent child runtimes.** TCA26's `Spawn` gives children their own
  cores with separate action routing. Lattice keeps one `LatticeCore` per `ViewModel`; children
  stay lensed scopes. Spawn is a second architecture, not an increment — out of scope even for
  this future plan. <!-- ponytail: one-core model; revisit only if routing depth becomes a measured cost -->
- **No `FeatureDynamicProperty` / runtime field reflection.** TCA26 mounts dynamic properties by
  walking type fields with `_fields(of:)` + raw pointers (`Feature.swift:79–120`). Lattice has
  no `@FeatureEnvironment`-style properties to mount; skip the machinery entirely.
- **No dependencies/environment system.** Same 1.0 decision of record.

---

## 2. Prerequisite — per-property observation of domain state

> **1.0 reality check (plan 05).** 1.0 ships `@FeatureState`/`@Domain` with **diff-at-commit**:
> the generated `_commit(old:new:registrar:key:)` compares view-visible members after every
> mutation and fires a per-ViewModel registrar side table, gated on output equality. There is
> **no access-tracking observation anywhere in 1.0** — state is a plain value, nothing fires at
> `willSet`, and `ViewStateReducer`/`@ObservableState` are deleted. That leaves two candidate
> remount drivers:
>
> - **(i) Access tracking as new machinery** — the design the rest of this section sketches.
>   Read it as *additive*, not a shared substrate: the macros and `withObservationTracking`
>   plumbing below share nothing with 1.0 observation (there is nothing to share); they would
>   be built from scratch on top of the diff-at-commit runtime, solely to give each node a
>   per-property dependency set.
> - **(ii) Drive remounts from commit diffs.** The funnel already computes which projection
>   key paths changed on each commit (`_commit` firing the registrar); extend the diff to also
>   cover `@Domain` members and each commit yields a dirty key-path set. Nodes register the
>   key paths their composition depends on — `Dynamic`'s `observing:` key path, `When`'s
>   presence path, `ForEach`'s collection path — and the drain remounts every node whose
>   registered paths intersect the dirty set. Tradeoff: no per-body dependency tracking (nodes
>   *declare* dependencies instead of having their reads observed), and remount granularity
>   equals the diff's key-path granularity — a member the diff treats as one unit is one dirty
>   key. In exchange: no new macros, no `willSet` machinery, no one-shot re-arming, and the
>   observation re-entrancy/storm risks (R1/R2) shrink to queue discipline. Since §4's
>   combinators are all key-path-declared anyway, (ii) plausibly covers them without free-form
>   tracking.
>
> Deep design of (ii) — and the choice between the two — is deferred to adoption time; the rest
> of §2 preserves the option-(i) design as originally drawn.

Under option (i), remount is *driven by observation*: a node's body evaluation reads state under
`withObservationTracking`, and a later mutation of any read property enqueues a re-mount of
exactly that node. 1.0 gives this nothing to build on: view notification is diff-at-commit
(plan 05), and domain state is a plain value with no observation hooks — so this prerequisite
is a new macro + runtime pair for the **domain** side, modeled on TCA26's
`@ValueObservable` / `@ValueObservationTracked`.

### 2.1 The TCA26 mechanism, ported to Lattice naming

TCA26's `ValueObservationTracked` embeds an `InlineObserved` box per property: an
`ObservationRegistrar` plus a *change strategy* chosen by overload resolution at the property
wrapper's init — `WhenNotEqual` for `Equatable`, `WhenNotIdentical` for `AnyObject`,
`OnLocationChange` for nested `ValueObservable` values (identity via a `ValueLocation` UUID),
`Always` otherwise. Reads register with the tracking scope; writes notify only when the
strategy says the value meaningfully changed. `@ValueObservable` (memberAttribute macro) sprays
`@ValueObservationTracked` over every stored property and adds `_$valueLocation`.

Lattice equivalents (new files under `Sources/Lattice/Observation/Domain/`, new macros in the
plugin):

```swift
/// Conformance stamped by the @ObservableDomainState macro.
public protocol ObservableDomainState {
    var _$stateLocation: DomainStateLocation { get }
}

/// Value identity for whole-value change detection. Transparently Codable/Hashable so
/// consumer state keeps synthesizing conformances that ignore it.
public struct DomainStateLocation { /* .none / .tag(Int) / uuid */ }

/// Property wrapper applied per stored property by the macro. Registrar + change strategy
/// chosen by init overload: Equatable ⇒ notify when not equal; AnyObject ⇒ when not
/// identical; nested ObservableDomainState ⇒ when _$stateLocation changed; otherwise always.
@propertyWrapper
public struct DomainStateTracked<Value> {
    public var wrappedValue: Value { get /* registrar.access */ set /* strategy-gated withMutation */ _modify }
    // init overload ladder: one overload per change strategy
}
```

Macro surface (plugin work — see §8/§10 for the binary-workflow cost):

```swift
/// Attached to a feature's DomainState struct or enum. Struct: applies @DomainStateTracked to
/// every eligible stored property (skipping @DomainStateIgnored), adds _$stateLocation, and
/// extends with ObservableDomainState. Enum: synthesizes _$stateLocation switching over cases
/// (payloadless ⇒ .tag(n); single .State payload ⇒ forwarded location).
@attached(memberAttribute)
@attached(member, names: named(_$stateLocation))
@attached(extension, conformances: ObservableDomainState)
public macro ObservableDomainState()

@attached(accessor) @attached(peer, names: prefixed(_))
public macro DomainStateTracked()

@attached(accessor, names: named(willSet))
public macro DomainStateIgnored()
```

Naming note: `@ObservableState` is deleted in 1.0 (plan 05), so the name is technically free —
but it named a copy-identity model this is not; don't reuse it. The `Domain` infix matches the
1.0 `@FeatureState`/`@Domain` vocabulary and marks this as interactor-side observation.
**Adoption is opt-in per feature**: a `DomainState` without the macro composes fine — its nodes
simply never observe anything, so they never remount (static behavior preserved, §7).

### 2.2 Two consumers of one commit — precise funnel ordering

Domain observation and the projection diff serve different masters and must not be conflated:

| Consumer | Reads | Fires | Drives |
|---|---|---|---|
| Remount tracking | domain-state properties, during body evaluation, under `withObservationTracking` | synchronously at `willSet`, **mid-mutation**, while `state` is `inout`-open | tree re-evaluation (enqueue only) |
| Projection diff | view-visible members, old vs. new, via the generated `_commit(old:new:registrar:key:)` | inside the `onCommit` host hook, after the remount drain | SwiftUI rendering (per-ViewModel registrar side table) |

The pinned 1.0 funnel (`mutate → presence detection → onCommit`) gains exactly one internal
stage, at the seam plan 02 §11.4 reserved:

```
mutate domain state
  ├─ (during the mutation) domain-observation onChange fires per touched property
  │    → enqueueRemount(path) — RECORD ONLY; never touch the core synchronously
  ↓
transition detection (presence-flipped nodes → prefix cancel, as today)
  ↓
★ remount drain (NEW): while remountQueue non-empty (bounded, §9 risk R1):
      pop node → dismount removed subtrees (prefix cancel + onDismount hooks)
                → re-evaluate body under fresh withObservationTracking
                → mount added subtrees (onMount hooks)
      hook mutations mutate state directly; each re-runs presence detection and may
      enqueue further remounts — loop to fixpoint (TCA26 runHooks' while loop,
      Core.swift:224–256)
  ↓
onCommit host hook — EXACTLY ONCE per external commit:
      projection diff — `_commit(old:new:registrar:key:)` fires the host-owned
      registrar for view-visible members whose output changed (plan 05)
  ↓
(send only) launch pending effects — including effects perform'd by lifecycle hooks
```

Two ordering guarantees this stage must uphold, both load-bearing:

1. **`onChange` callbacks only enqueue.** Observation's `willSet` fires while the mutation holds
   exclusive `inout` access to `state` (plan 02's `.modifying`/`.updating` phases). Any
   synchronous core touch from there is the re-entrancy trap plan 02's preconditions exist to
   catch. TCA26 does exactly this — `observeForRemount`'s `onChange` calls
   `unsafeCore?.enqueue { ... }` and returns (Core.swift:176–195). The Lattice port enqueues
   `(path, generation)` and nothing else.
2. **The projection diff sees post-remount state, once.** All lifecycle-hook mutations fold into the
   same external commit: the view never renders a half-remounted intermediate, and
   `TestViewModel` sees one commit whose `changes` closure covers send + hooks together — unless
   the recorder asks for finer grain (§6). This is why the drain sits *before* `onCommit`, not
   inside it.

Effect-phase `modify` commits run the identical funnel (single choke point, unchanged
principle): a `modify` that flips a branch condition remounts before the projection diff runs.

---

## 3. Runtime evolution — how `LatticeCore` grows

Plan 02 §11 left four seams. This section names exactly which plan-02 types/members **change**
versus **extend untouched**.

### 3.1 Changes (signature or shape edits to plan-02 code)

| Plan-02 member | 1.0 shape | Dynamic-body shape | Why |
|---|---|---|---|
| `tasks: [GraphPath: [EffectLocation: [EffectTaskEntry]]]` | flat task dict | `storage: [GraphPath: NodeStorage]`; the location→entries dict moves inside `NodeStorage` alongside generation + caches | remount needs per-node bookkeeping (generation, body cache, hook state) at the same key as the tasks; two parallel dicts keyed by the same path is strictly worse. `cancelTasks(at:/withPrefix:)`, `hasTasks(at:)`, `currentTasks(at:)` keep their **signatures**; bodies re-target `storage[key.path]?.taskBuckets`. This changes the README-pinned storage sentence (§8). |
| `mount(interact:)` + `private var interact` | one routing closure, installed once | `mount(root: some Interactor<DomainState, Action>)` — the core keeps the root value and routes through the **registered node tree** (cached per-node body values), TCA26 `register`/`Storage.feature` style | per-action `body` re-evaluation (1.0's default-`interact` forwarding) is incompatible with observation-tracked mounting: the tracked evaluation must happen once per (re)mount, and routing must use the *cached* value or tracking registrations go stale. Plan 02 §11.2 anticipated "closure swap"; the real shape is closure-per-node, swapped per-node on remount. |
| `presenceWatchers: [PresenceWatcher]` + `registerPresenceWatcher` | append-only array | keyed registration with prefix deregistration: `removePresenceWatchers(withPrefix:)` | plan 02 §11.3 predicted this exactly ("deregisters by `watchers.removeAll { $0.path.starts(with: prefix) }`"); the registration API itself is unchanged. |
| `runCommitFunnel` | mutate → presence → `onCommit` | gains the remount-drain stage between presence detection and `onCommit` (§2.2) | plan 02 §11.4's reserved slot. `onCommit` stays a single host hook — the "becomes an array" option is not needed; the drain is an internal stage, not a host hook. |
| `UpdateContext` | one per `send` | also constructed per lifecycle-hook execution (hooks are micro update-phases so `effects.perform` works inside them, §4.4) | keeps the phase-discipline preconditions uniform: `perform` legal in hooks, `modify`/`send` not. |

### 3.2 Extensions (new members; nothing existing touched)

```swift
/// Per-node bookkeeping: task buckets, mount generation, cached body, and lifecycle-hook
/// state, keyed by the node's GraphPath.
final class NodeStorage {
    /// Effect task buckets for this node, keyed by launch location.
    var taskBuckets: [EffectLocation: [EffectTaskEntry]] = [:]

    /// Monotonic mount generation. Bumped on every (re)mount and on invalidation, so a stale
    /// observation callback (armed under generation N, firing after remount N+1) is dropped.
    var generation: UInt64 = 0

    /// Cached type-erased body value + child-path cache: body is evaluated once per mount,
    /// routed from thereafter.
    var cachedBody: Any?
    var childPaths: [AnyKeyPath: GraphPath] = [:]

    /// Lifecycle-hook state: onMount fired flag, onChange oldValue + generation stamp.
    var hookState: [ObjectIdentifier: Any] = [:]

    /// Deferred dismount work (onDismount task), run exactly once.
    var dismountTask: (() -> Task<Void, Never>?)?

    func invalidate() { generation &+= 1 }
}

/// The remount queue drained by the commit funnel.
private var remountQueue: [PendingRemount] = []
private var isRemounting = false        // suppress onChange enqueues during re-evaluation
private var onChangeGeneration: UInt64 = 0  // one bump per funnel pass; onChange dedupe

struct PendingRemount {
    let path: GraphPath
    let generation: UInt64   // must match storage[path].generation at drain time
    let remount: () -> Void  // re-runs the node's mount function
}

/// Wraps one node's body evaluation in observation tracking; a change to any read property
/// enqueues a remount of exactly this node, guarded by generation and dismount checks.
func observeForRemount<T>(
    of storage: NodeStorage,
    path: GraphPath,
    remount: @escaping () -> Void,
    apply: () -> T
) -> T {
    storage.generation &+= 1
    let mountGeneration = storage.generation
    // Safe: only dereferenced from enqueued work that runs in-domain (funnel drain).
    weak nonisolated(unsafe) let weakSelf = self
    weak nonisolated(unsafe) let weakStorage = storage
    nonisolated(unsafe) let remount = remount
    let wasRemounting = isRemounting
    isRemounting = true
    defer { isRemounting = wasRemounting }
    return withObservationTracking {
        apply()
    } onChange: {
        // Fires at willSet, possibly mid-mutation with `state` inout-open: ENQUEUE ONLY.
        guard weakSelf?.isRemounting != true else { return }
        weakSelf?.enqueueRemount(
            PendingRemount(path: path, generation: mountGeneration, remount: remount)
        )
    }
}

/// Tears down one subtree: cancels tasks by prefix, runs onDismount hooks leaf-first, and
/// drops node storage and presence watchers under the prefix.
func dismountSubtree(prefix: GraphPath) {
    for path in storage.keys where path.starts(with: prefix) {
        if let dismount = storage[path]?.dismountTask { pendingDismountTasks.append(dismount) }
        storage[path]?.invalidate()
    }
    cancelTasks(withPrefix: prefix)
    removePresenceWatchers(withPrefix: prefix)
    for path in Array(storage.keys) where path.starts(with: prefix) { storage[path] = nil }
}
```

Drain loop, inside `runCommitFunnel` after presence detection:

```swift
private func drainRemounts() {
    var passes = 0
    while !remountQueue.isEmpty {
        passes += 1
        precondition(passes < 128, remountStormMessage)   // a remount storm is an app bug; fail loudly, don't spin
        onChangeGeneration &+= 1
        let queue = remountQueue
        remountQueue.removeAll(keepingCapacity: true)
        for pending in queue {
            guard !isDismounted,
                  storage[pending.path]?.generation == pending.generation
            else { continue }   // stale: node was remounted/dismounted since enqueue
            pending.remount()   // dismount-diff + re-evaluate + mount; may enqueue more
        }
    }
}
```

### 3.3 Untouched plan-02 surface

`GraphPath` (components + FNV hash + `starts(with:)` are already exactly the remount
primitives), `EffectLocation`/`TaskKey`, the composite send task backing `EventTask`,
`send`/`modify` phase preconditions, deferred effect launch + `EffectTaskEntry`,
`Task.immediateIfAvailable`/`StartOnMainActor`, `dismount()`/`deinit` teardown, `onCommit` /
`onEffectLaunched` hook shapes (plan 07's `origin` parameter gains one case, §6). The weak-
capture invariant extends to observation callbacks: every `onChange` closure captures the core
and node storage `weak nonisolated(unsafe)`, dereferenced only in-domain — same justification
discipline as plan 02 §9.4.

---

## 4. API surface

Design rule, restated: **`interact` stays.** Dynamic composition enters through new
builder nodes and modifiers, not through a TCA-style `Update`/`body`-only protocol. The
`Interactor` protocol from the README contract is unchanged; `body` remains state-less and
`@InteractorBuilder`-built. State-dependence lives where TCA26 puts it — in combinators whose
*mount* reads state under observation — plus one explicit value-keyed escape hatch.

### 4.1 `When` grows a real lifecycle (no signature change)

Under the dynamic runtime, the existing `Interactors.When(state:action:)` over an optional or
case path stops being a mere router: its mount function reads presence under observation
(`_ = casePath.extract(from: state) != nil`, exactly TCA26's `SpawnIfLetFeature` remount
trigger), so case entry mounts the child subtree (running its `onMount` hooks) and case exit
dismounts it (onDismount hooks + the same prefix cancel the 1.0 presence watcher does). Consumer
code is unchanged; behavior is a strict superset. The 1.0 presence watcher becomes the degenerate
form of this mount function and is subsumed by it for dynamic-enabled features.

### 4.2 `Interactors.ForEach` — per-element identity and effects scoping

```swift
extension Interactors {
    /// Runs a child interactor for each element of an identified collection, mounting and
    /// dismounting element subtrees as the collection changes.
    ///
    /// Element identity — not position — keys everything: the element's GraphPath component
    /// is `.id(element.id)`, so effects launched by row 3's child die when row 3 is deleted,
    /// survive reordering, and never collide with row 4's.
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     Interactors.ForEach(state: \.rows, action: \.row, id: \.id) {
    ///         RowInteractor()
    ///     }
    ///     Interact { state, action, effects in ... }
    /// }
    /// ```
    public struct ForEach<
        ParentState, ParentAction,
        Data: MutableCollection & RandomAccessCollection,
        ID: Hashable,
        Child: Interactor
    >: Interactor where Child.DomainState == Data.Element {
        public init(
            state toElements: WritableKeyPath<ParentState, Data>,
            action toElementAction: CaseKeyPath<ParentAction, (ID, Child.Action)>,
            id: KeyPath<Data.Element, ID>,
            @InteractorBuilder<Data.Element, Child.Action> child: () -> Child
        )
        // interact: extracts (id, childAction); resolves the element by id with a cached-index
        // fast path; runs the child with an Effects handle scoped through an id-resolving
        // element lens at path parentPath + .keyPath(\.rows) + .id(AnyHashable(id)).
        // Absent id ⇒ action dropped (same contract as case-exited When).
    }
}
```

Mount function (runs at mount and on every remount triggered by the collection property):
diff current element IDs against the node's cached ID list (TCA26
`_hasStructuralChange`, Spawn.swift:598–625). Removed IDs ⇒ `dismountSubtree(prefix:
elementPath)`. Added IDs ⇒ mount child subtree at `.id(elementID)` (running its onMount hooks).
Unchanged IDs ⇒ nothing — element *value* changes don't remount, they're ordinary state the
child reads. Element `EffectState.modify` pulls back through an id-resolving lens: if the id has
left the collection, the mutation is dropped and the element bucket cancelled — the pinned
dismissed-mid-request contract, extended element-wise.

Requirements kept minimal: no `RangeReplaceableCollection` bound (Lattice's ForEach doesn't
delete elements; there is no dismiss-handler machinery to port because Lattice has no
`@Environment(\.dismiss)` analog). `ID` is the consumer's, via key path — no `ValueLocation`
identity needed on the collection side.

### 4.3 State-reading composition — `Interactors.Dynamic`

The general "body takes state" closure (`(State) -> some Interactor`) is deliberately **not**
the shape: an unconstrained closure re-evaluated on any read property invites remount storms
and makes structural identity depend on whatever the closure happened to touch. Instead, the
escape hatch is value-keyed, following TCA26's `.id(_:)` / `onMount(id:)` pattern — the
observed value *is* the remount key, and it must be `Equatable` so no-op writes don't churn:

```swift
extension Interactors {
    /// Rebuilds its subtree whenever `keyValue` changes. The extracted value is appended to
    /// the subtree's GraphPath as an `.id` component, so a key change is a full dismount
    /// (tasks cancelled, onDismount hooks) followed by a fresh mount under the new key.
    ///
    /// ```swift
    /// Interactors.Dynamic(observing: \.mode) { mode in
    ///     switch mode {
    ///     case .browse: BrowseInteractor()
    ///     case .edit:   EditInteractor()
    ///     }
    /// }
    /// ```
    public struct Dynamic<ParentState, ParentAction, Key: Hashable & Equatable, Child: Interactor>:
        Interactor
    where Child.DomainState == ParentState, Child.Action == ParentAction {
        public init(
            observing key: KeyPath<ParentState, Key>,
            @InteractorBuilder<ParentState, ParentAction> child: @escaping (Key) -> Child
        )
        // Mount: reads state[keyPath: key] under observeForRemount; child path component is
        // .id(keyValue). Remount with an unchanged key is a no-op (Equatable gate).
        // The closure must be pure given its key — same purity contract body already carries,
        // narrowed to one value.
    }
}
```

This covers `if state.isPremium { ... }` (`observing: \.isPremium`, `Bool` key) and
mode-switching, while keeping remount frequency exactly one-per-key-change and structural
identity printable in a failure message. If real-world usage later demands the free-form
closure, it layers on top of the same machinery — start constrained. <!-- ponytail: value-keyed only; free-form (State) -> Interactor builder only if Dynamic proves insufficient -->

### 4.4 Lifecycle modifiers

```swift
extension Interactor {
    /// Runs once when this interactor's node mounts (feature init, case entry, forEach
    /// element insertion, Dynamic key change). Runs as a micro update-phase: mutate state,
    /// launch effects; effects launch after the enclosing commit, into this node's buckets.
    public func onMount(
        _ handler: @escaping (inout DomainState, Effects<DomainState, Action>) -> Void
    ) -> some Interactor<DomainState, Action>

    /// Runs when this node dismounts (case exit, element removal, Dynamic key change, host
    /// teardown), after the subtree's tasks are cancelled. Receives the final state by value —
    /// the node's state slice may already be gone. Async: cleanup may need to flush.
    public func onDismount(
        _ handler: @escaping (DomainState) async throws -> Void
    ) -> some Interactor<DomainState, Action>

    /// Runs when `value` changes between commits (oldValue cached in node storage; the
    /// onChangeGeneration stamp prevents double-fire when several remount passes see the
    /// same change).
    public func onChange<V: Equatable>(
        of value: KeyPath<DomainState, V>,
        initial: Bool = false,
        _ handler: @escaping (_ old: V, _ new: V, _ state: inout DomainState,
                              _ effects: Effects<DomainState, Action>) -> Void
    ) -> some Interactor<DomainState, Action>
}
```

Divergences from TCA26, and why:

- **Hooks receive the `Effects` handle** instead of TCA26's implicit `addTaskContext`. Lattice's
  effect API is the explicit handle everywhere else; hooks should not be the one place effects
  appear by side-channel. Each hook runs under its own `UpdateContext` (§3.1) so `perform` is
  legal and `modify`/`send` correctly trap — a hook is a mini `interact`.
- **`onChange` takes a key path**, not a value: `body` never sees state in Lattice, so there is
  no expression position where a state-derived value could be passed. The key path is also the
  observation registration, for free.
- **`onDismount` is async throws** (matches TCA26): its task launches through the normal
  deferred-launch path and joins the enclosing commit's composite send task so `EventTask`/
  `finish()` cover teardown work.

These modifiers compose in `body` and are inert combinator wrappers under the 1.0 static
runtime? **No — they do not exist in 1.0 at all.** They ship only with this workstream, gated
on the dynamic runtime, to avoid shipping silently-dead API (§7).

---

## 5. Plan-02 seam map — each §11 seam, consumed

| Plan 02 §11 seam | How this plan consumes it |
|---|---|
| **§11.1 — path-keyed task storage with prefix cancellation** (`tasks: [GraphPath: ...]`, `cancelTasks(withPrefix:)`) | `dismountSubtree(prefix:)` (§3.2) is `cancelTasks(withPrefix:)` plus hook execution plus storage removal. "Remounting a subtree is cancel prefix, keep siblings" holds verbatim: `ForEach` element removal cancels `parent + .keyPath(\.rows) + .id(x)` without touching `.id(y)`; `Dynamic` key change cancels its `.id(oldKey)` subtree. The storage *shape* changes (§3.1) but the keying and prefix semantics are exactly what §11.1 promised. |
| **§11.2 — `mount(interact:)` stores a swappable `var`** | Consumed and generalized: the single root closure becomes per-node cached mount state (`NodeStorage.cachedBody` + child routing), and "remount is a closure swap plus a prefix cancel" becomes `pending.remount()` in the drain loop — swap the node's cached body, cancel the changed prefix. The single-funnel property (`send` is the only router entry) is preserved. |
| **§11.3 — `presenceWatchers` carry their `GraphPath`** | Consumed exactly as written: `removePresenceWatchers(withPrefix:)` implements the predicted `removeAll { $0.path.starts(with: prefix) }`; re-registration on remount uses the unchanged `registerPresenceWatcher(path:isPresent:)` API. For dynamic-enabled features the watcher's job is absorbed into `When`'s mount function (§4.1); static features keep using watchers untouched. |
| **§11.4 — `runCommitFunnel` is the only post-mutation choke point** | The remount drain (§2.2, §3.2) slots in between transition detection and `onCommit`, "without touching `send`/`modify` call sites" — confirmed: neither entry point changes; both flow through the extended funnel. TCA26's `postProcessingHooks` equivalent is the `remountQueue` + `pendingDismountTasks`, drained here and only here. |

One seam plan 02 did *not* anticipate: per-action `body` re-evaluation in the default
`interact` forwarding (plan 04) conflicts with mount-time cached bodies (§3.1, `mount` row).
That is the single structural amendment this plan needs beyond the four seams — flagged in §7.

---

## 6. Testing impact (plan 07 contract)

Plan 07's engine-sharing thesis carries over unchanged: `TestViewModel` hosts the same
`LatticeCore`, so mount/dismount/remount are exercised by the real machinery, not a mirror.
Deltas to the plan-06 contract:

1. **`CommitOrigin` gains one case.** Plan 07 §2 pinned
   `.send(Action)` / `.modify` / `.presenceCancellation`. Lifecycle-
   hook mutations fold into the enclosing commit (§2.2), so they do *not* produce separate
   commits — but the recorder needs to attribute tree edits. Add:
   `case lifecycle(LifecycleEvent, GraphPath)` where
   `enum LifecycleEvent { case mounted, dismounted, changed }`, emitted once per tree edit
   during the remount drain (state-carrying, like `.presenceCancellation`). Under
   exhaustivity `.on`, unasserted lifecycle events fail at deinit like any pending commit.
2. **New assertions**, spelled in plan 07/09's house style:

   ```swift
   let model = TestViewModel(initialDomainState: .init(), feature: feature)
   await model.send(.showDetail) { $0.detail = DetailState() }
   await model.expectMounted(\.detail)          // the When subtree mounted
   await model.expect { $0.detail?.isWarm = true }   // its onMount hook's effect committed
   await model.send(.dismiss) { $0.detail = nil }
   await model.expectDismounted(\.detail)       // tasks cancelled + onDismount ran
   ```

   `expectMounted`/`expectDismounted` consume `.lifecycle` entries; matcher is a state key
   path / case path resolved to a `GraphPath` prefix.
3. **Registration snapshots, TCA26 TestCore style.** TCA26's `TestCore.register()` diffs
   pre-registration / post-registration / post-hooks state snapshots and records each delta as
   a `ReceivedInput` (TestCore.swift:428–453) — initial `onMount` hooks that mutate state are
   assertable, not invisible. Lattice equivalent: `TestViewModel` init records the
   initial-mount pass's lifecycle events and any hook-mutation commit as pending items, so a
   feature whose root `onMount` mutates state fails exhaustivity until asserted:
   `await model.expect(initial:) { $0.cacheWarm = true }`.
4. **Effect observation is already sufficient.** `onEffectLaunched(TaskKey, Task)` carries the
   `GraphPath`, so per-element `ForEach` effect launches and their cancellation on element
   removal assert with existing plan-06 machinery — no new hook.
5. **New suites**: `DynamicMountTests` (When case entry/exit lifecycle, hook effect scoping,
   onDismount-after-cancel ordering), `ForEachIdentityTests` (insert/remove/reorder; effect
   survival under reorder; dropped `modify` after element removal), `RemountStormTests`
   (onChange writing its own observed value trips the bounded-drain precondition; `TestClock`-
   paced oscillation), `DynamicObservationTests` (property-granular remount: mutating an
   unread property does not remount; `@DomainStateIgnored` respected).

---

## 7. Migration & compatibility

**Consumer-facing: strictly additive.** A 1.0 feature — no `@ObservableDomainState`, no dynamic
combinators, no lifecycle modifiers — compiles and behaves identically: its nodes register no
observation, enqueue no remounts, and the drain stage is a no-op on an empty queue. The static
fast path must stay allocation-free in the funnel (gate in §9's phasing).

**Plan-internal: not purely additive.** Concrete renegotiation points against the README
contract and sibling plans, to be amended *before* implementation starts:

| Document | Pinned statement | Amendment needed |
|---|---|---|
| README "Decisions of record" | "Composition tree is **static**, built once"; "No dynamic body re-evaluation now" | Rewrite to "static by default; dynamic nodes opt in" and delete the "now" clause. This is the headline contract change. |
| README "Core runtime commit path" | `Task storage: [GraphPath: [Location: Task]]` | Re-pin as `[GraphPath: NodeStorage]` with buckets inside (§3.1). Same keys, same semantics, one indirection. |
| README funnel diagram | mutate → transition detection → projection diff | Insert the remount-drain stage between transition detection and the projection diff (§2.2). |
| Plan 02 §3.5 | `mount(interact:)` single closure; `interact` re-evaluated via plan 04's default forwarding | `mount(root:)` + per-node cached bodies (§3.1). The **§4 internal-API table** row for `mount` changes; every other row survives. |
| Plan 04 §1 / §6 | "`body` must be a pure, stable description… same structure every time"; `Conditional`: "the branch taken is fixed… must not change" | Relax per-node: static nodes keep the contract; `Dynamic`/`ForEach` subtrees restate it as "pure given the observed key / element id". `Conditional` doc gains "for runtime branching, use `Interactors.Dynamic`." |
| Plan 04 default `interact` | forwards to `body` per action | routes through the mounted cache for dynamic-enabled trees (§5, last paragraph). Leaf and custom-`interact` semantics unchanged. |
| Plan 06 | ViewModel init: build tree, `core.mount`, done | init now runs the initial mount pass (root register + hook drain) before returning; initial `onMount` effects need caller-visible coverage — surface the composite task of the mount pass's launched effects via a new `viewModel.mountTask`, or fold into first send (decide at adoption; TCA26 stores `initialTask`, Core.swift:938–941). The `onCommit` projection-diff wiring itself is untouched. |
| Plan 07 §2 | `CommitOrigin` three cases | add `.lifecycle` (§6.1). |
| Plan 08 | plugin work is bounded to `@Interactor` (survives), the plan-10 deletions, and `@FeatureState`/`@Domain` (new) | Two–three more macros land in the plugin (§2.1), requiring `scripts/rebuild-macro.sh` + podspec `-load-plugin-executable` verification for the new names + a fresh `LatticeMacrosTests` suite for the domain-observation macros. Plan 08's audit method (grep gates, syntax-only expansion tests) is reusable as-is. Moot if §2's option (ii) is chosen — no new macros at all. |

No deletions: the presence-watcher path, the flat routing for static features, and all of plans
03/06's public API survive verbatim.

---

## 8. Honest cost accounting

What the reference implementation spends on this capability:

| TCA26 component | Lines | Lattice port needs |
|---|---|---|
| `Internal/Core.swift` | ~2,150 | ~40% — no core protocol hierarchy (Lattice keeps its one concrete `LatticeCore`), no Scoped/IfLet/IfCaseLet core classes (lenses stay in `Effects`), no InertCore/SpawnedCore, no environment/preferences/events/breadcrumbs/change-debugger. Ports: observeForRemount, Storage/generation, register/deregister, enqueueDismount, ForEach reconciliation + element index cache. Estimate **800–1,000 new lines** in `LatticeCore` + `NodeStorage`. |
| `Features/Spawn.swift` | 849 | not ported (no spawn); ForEach reconciliation logic (~200 lines) is ported from `SpawnForEachFeature`/`ForEachCore` instead. |
| `ValueObservation/*` | ~450 | ~full port (§2.1): the change-strategy overload ladder and `_modify` accessor subtleties are the hard-won part — copy, don't reinvent. **~450 lines.** |
| `FeatureModifiers/On{Mount,Change,Dismount}.swift` | ~300 | ~full port, reshaped onto `Effects` (§4.4). **~250 lines.** |
| Macros (`ValueObservableMacro` + tracked/ignored) | ~600 | ~full port with renames, incl. the enum `_$stateLocation` synthesis and `#if` handling. **~550 plugin lines + test suite.** |
| `Testing/TestCore.swift` lifecycle parts | ~300 of 1,660 | recorder extension + new assertions (§6). **~250 lines.** |

**Relative effort: roughly 0.7–1.0× the entire 1.0 rework** (plans 02+04+06 were the load-
bearing bulk; this reprises all three at similar depth, minus the deletion/migration work, plus
macro work 1.0 didn't have). It is the single largest possible post-1.0 workstream. That is the
honest price of the four §1 capabilities, and why 1.0 was right to defer it.

**Availability/toolchain implications: none that move floors.**
`withObservationTracking`/`ObservationRegistrar` are iOS 17+/macOS 14+ — inside the existing
floor. No new `@_silgen_name`, no OS-26-gated API (the launch shim story is untouched). One
watch item: `withObservationTracking`'s `onChange` is one-shot; every remount must re-arm
(TCA26 relies on this too — re-registration happens naturally because remount re-runs
`observeForRemount`). Swift 6.2 tools floor unchanged; swift-syntax pin unchanged (the new
macros build against whatever plan 01 pinned). The macro-binary workflow (consumer-generated at
`pod install`, never checked in) gains new macro names to cover — a process cost, not a
toolchain cost (§9 R3).

---

## 9. Phasing & gates

Strictly sequential; each phase lands green and independently revertable. D0–D1 are invisible
to consumers.

| Phase | Contents | Gate |
|---|---|---|
| **D-1: Contract amendment** | README + plan 02/04/06/07/08 amendments (§7 table). No code. | Sibling-plan owners sign off; README updated first per its own rule. |
| **D0: Domain observation** | `@ObservableDomainState` / `@DomainStateTracked` / `@DomainStateIgnored` macros + runtime types (§2.1). No core changes. | `swift test --filter LatticeMacrosTests` green incl. new suites; macro binary rebuilt via `scripts/rebuild-macro.sh` + podspec plugin-flag smoke test; a `@ObservableDomainState` state in `LatticeTests` compiles with zero behavior change (no consumer of the registrations yet); grep gate: zero `Sendable` additions. |
| **D1: NodeStorage + funnel stage** | Storage reshape (§3.1), `observeForRemount`, remount queue + bounded drain, `dismountSubtree`. No public API; `When` presence still via watchers. | Full 1.0 suite green *unchanged* (proves static-path compat); new `CoreRemountTests` (generation staleness, enqueue-only onChange under `isMutating`, drain fixpoint, storm precondition); perf gate: funnel cost for a no-dynamic feature within noise of 1.0 baseline (micro-benchmark, ±5%); TSan pass on the new weak-capture sites. |
| **D2: Lifecycle modifiers** | `onMount`/`onDismount`/`onChange` (§4.4) + hook micro-update-phases + plan-06 recorder `.lifecycle` origin + `expectMounted`/`expectDismounted`. | `DynamicMountTests` + recorder tests green; hook `effects.perform` lands in the node's bucket (assert via `onEffectLaunched` key); onDismount runs after task cancellation, exactly once, incl. host-teardown path. |
| **D3: Dynamic `When`** | Case/optional `When` mount functions replace presence watchers for dynamic-enabled features (§4.1). | Existing `When` scoping suite green with both runtimes' semantics (drop + cancel contract unchanged); case-entry `onMount` / case-exit `onDismount` covered; mixed tree (static parent, dynamic child) covered. |
| **D4: `ForEach` + `Dynamic`** | §4.2 + §4.3, element lens pullback in `Effects`, ID reconciliation. | `ForEachIdentityTests` (insert/remove/reorder/effect-survival/dropped-modify); `Dynamic` key-change dismount-remount cycle; `RemountStormTests` trips the bounded drain with the documented message. |
| **D5: Docs & release** | README/skills/ExampleProject additions, migration notes ("nothing to migrate; here's what's new"), minor-version release (additive). | Plan-08-style gates: docs build, example project exercises ForEach + onMount, podspec version bump. |

---

## 10. Top risks

- **R1 — Remount storms.** An `onChange` handler that writes a property its own node observes,
  or two `Dynamic` nodes keyed on values each other's hooks toggle, loops the drain forever.
  TCA26 mitigates with `onChangeGeneration` dedup but loops unbounded in the adversarial case.
  Lattice: generation dedup **plus** the bounded drain (`passes < 128`) with a loud
  precondition naming the offending `GraphPath`s — a storm is an app bug and must say so,
  not spin. Covered by `RemountStormTests` (D4 gate). <!-- ponytail: fixed pass cap; make it configurable only if a legitimate >128-pass tree ever exists -->
- **R2 — Observation-driven re-entrancy.** `onChange` fires at `willSet`, mid-mutation, with
  `state` `inout`-open — any synchronous core touch from there is the exclusivity trap plan 02's
  phase preconditions exist to catch. The enqueue-only rule (§2.2) is the whole defense;
  it is enforced by construction (the closure calls exactly `enqueueRemount`) and by a D1 test
  that fails if a remount executes during a mutation phase. Secondary exposure: hook micro-update-
  phases nest inside the funnel — their `UpdateContext` handling must not corrupt the outer
  send's pending-effect list (D2 test: hook effects and send effects launch in deterministic
  order, each in the right bucket).
- **R3 — Macro complexity on the binary workflow.** Plan 08's plugin surface grows again (it
  already carries `@FeatureState`/`@Domain`): three new macros mean consumer-side rebuilds,
  podspec `-load-plugin-executable` coverage for the new names, and the overload-ladder subtleties of
  `DomainStateTracked` (nine `init` overloads whose resolution silently picks the change
  strategy — a wrong pick is a silent observation bug, not a compile error). Mitigation: port
  TCA26's overload set verbatim with a dedicated resolution test per strategy; reuse plan 08's
  grep/audit gates; rebuild the binary once per phase that touches the plugin (D0 only).
- **R4 — Two mental models.** Static features (body-per-action, presence watchers) and dynamic
  features (cached bodies, mount functions) coexist in one runtime. Divergence in edge-case
  semantics (e.g. when exactly a case-exit cancels) would be a support nightmare. Mitigation:
  D3's gate runs the *same* scoping contract suite against both paths; the dismissed-mid-request
  contract is asserted to be behaviorally identical.
- **R5 — Per-element path hashing/AnyHashable cost.** `ForEach` puts `AnyHashable(id)` in hot
  storage keys; large collections churn `GraphPath` hashing on every reconciliation. The FNV
  incremental hash keeps per-path cost O(1), and reconciliation diffs IDs before touching
  paths (TCA26's contiguous-storage fast path, Spawn.swift:602–611 — port it). D4 gate includes
  a 1k-element reconciliation benchmark.
- **R6 — Weak-capture discipline expands.** Every `observeForRemount` arms a closure holding
  `weak nonisolated(unsafe)` core/storage refs that outlive arbitrary suspensions (observation
  callbacks fire whenever the property is next written). A single strong capture resurrects the
  1.0 deinit-story bug class. Mitigation: same `// Safe:` justification + grep gate + TSan
  discipline as plan 02 §9.4, extended to the new sites (D1 gate).

# Plan 05 — Feature State: `@FeatureState` / `@Domain`

Workstream 5 of the Sendable-removal rework. This plan flattens the domain-state → view-state
split into a **single annotated state type** and replaces the entire ViewStateReducer layer and
the `@ObservableState` copy-identity machinery with **diff-at-commit** against a host-owned
registrar. It lands with plan 6 (it defines what the ViewModel hosts) and feeds plan 8's macro
workstream. Conforms to the shared design contract in `README.md`; any deviation requires a
README update first.

## 1. Overview

Today a feature carries four artifacts: a domain state, a handwritten `ViewState` struct
annotated `@ObservableState`, a `ViewStateReducer` that maps one to the other, and a `Feature`
value that bundles interactor + reducer + an `areStatesEqual` strategy. Observation works by
copy-identity: the `@ObservableState` macro embeds an `ObservationStateRegistrar` and `_$id`
into the value, `_$willModify` fires at `willSet`, and the ViewModel performs a working-copy
exclusivity dance so in-place reducer mutation notifies per property.

After this plan, a feature carries **one state type**:

```swift
@FeatureState
struct SearchState {
    @Domain var rawResults: [SearchResult]     // interactor-only: invisible to views, never diffed
    var query: String                          // view-visible: projected, diffed by == at commit
    var subtitle: String {                     // computed & visible: derived view output,
        "\(rawResults.count) results"          //   diffed by == of its output at commit
    }
}
```

The load-bearing ideas:

- **Uniform visibility rule.** Every member is view-visible unless marked `@Domain` or
  `private`. Two annotations total; there is no third "reduced/derived" marker — a visible
  computed property *is* derived view output by definition. Visible stored properties are
  projected and diffed by `==`; visible computed properties are diffed by `==` of their output
  against a host-side cached copy, computed at most once per commit and only when some view
  has actually read them.
- **The generated reducer is a diff.** `@FeatureState` generates
  `_commit(old:new:registrar:key:)`: stored members are compared by `==` and fire the
  registrar on change; computed members are handed to the registrar's `commitDerived`, which
  evaluates them at most once, compares against the cached output, and skips them entirely
  when unobserved. This per-property output-equality gating
  replaces today's whole-ViewState `areStatesEqual` gate — granularity comes for free instead
  of being an all-or-nothing equality strategy.
- **The generated view surface is a projection.** Only non-`@Domain`, non-private members are
  reachable from a view — enforced at compile time by a generated key-path namespace, not by
  runtime filtering. `ViewModel` is `@dynamicMemberLookup` over the projection; projections
  chain for nested `@FeatureState` members.
- **State stays a plain value.** No embedded registrars, no `_$id`, no copy-identity, nothing
  fires at `willSet`. The registrar is a per-ViewModel side table keyed by projection key
  path; it owns both the observation signals and the derivation cache (each derived member's
  last committed output). View access registers through the projection's subscripts; the
  core's commit funnel (plan 02 §4 `onCommit`) wraps `_commit` in a registrar batch, which
  fires exactly the changed keys — once each — and bubbles fine-grained fires up the key
  hierarchy so the root whole-state slot (and interior subtree slots) support coarse
  observation through the same mechanism. The
  working-copy/exclusivity dance in today's ViewModel dies with `_$willModify`.
- **Collections of features** get an identity-keyed diff: structural changes ping `ForEach`
  identity once; same-ID elements that compare equal are skipped entirely; changed elements run
  their own `_commit` under per-element keys. This is the design's centerpiece (§6).

Everything in this plan is additive until plan 6 flips the ViewModel; the deletion list (§10)
executes then.

## 2. Programming model

### 2.1 The two annotations

| Annotation | Attaches to | Meaning |
|---|---|---|
| `@FeatureState` | structs and enums | Generates the projection namespace, the key-path map, the derived-member set, and `_commit`; adds `FeatureStateProtocol` conformance. |
| `@Domain` | stored **and** computed members | Marker: excluded from projection and diff. A computed `@Domain` member is an interactor-side helper. No code is generated for it. |

Declarations (in `Sources/Lattice/FeatureState/FeatureStateMacros.swift` — SwiftPM cannot
build two same-named files in one target, so the file cannot be named `Macros.swift`
alongside the existing top-level `Sources/Lattice/Macros.swift`):

```swift
@attached(member, names: named(_ViewMembers), named(_viewKeyPaths), named(_derivedMembers), named(_commit), arbitrary)
@attached(extension, conformances: FeatureStateProtocol)
public macro FeatureState() =
    #externalMacro(module: "LatticeMacros", type: "FeatureStateMacro")

/// Marker only; expansion is empty. `@FeatureState` reads it during its own expansion.
@attached(peer)
public macro Domain() =
    #externalMacro(module: "LatticeMacros", type: "DomainMacro")
```

`arbitrary` covers the enum case accessors (§4.2). `@Domain` follows the same no-op pattern as
today's `ObservationStateIgnored`.

### 2.2 Visibility matrix

| Member | Projected? | Diffed at commit? |
|---|---|---|
| stored, no marker | yes | by `==` of the stored value |
| computed get-only, no marker | yes | by `==` of its output against the host-cached output, computed at most once per commit, skipped when unobserved |
| stored `@Domain` | no | never |
| computed `@Domain` | no | never |
| `private` (stored or computed) | no | never |
| computed with a setter, no marker | **error** — visible computed properties are get-only by construction (§9) |

All visible members must be `Equatable`; §8 covers how the diagnostic is delivered.

### 2.3 Consumer view of the world

```swift
struct SearchView: View {
    let viewModel: ViewModel<SearchState, SearchAction>

    var body: some View {
        VStack {
            TextField("Search", text: viewModel.binding(\.query, event: SearchAction.queryChanged))
            Text(viewModel.subtitle)          // registers (subtitle); re-renders only when
        }                                     //   the derived output actually changes
        .task { await viewModel.sendViewEvent(.onAppear).value }
    }
}
```

`viewModel.subtitle` resolves through `@dynamicMemberLookup` against the projection.
`viewModel.rawResults` **does not compile** — `@Domain` members are absent from the generated
key-path namespace, so the failure is an ordinary "no member" error at the call site.

**Inline chained reads are coarse.** `viewModel.detail.title` written inline resolves through
the leaf subscript (a constraint-solver scoring consequence, see §3.5) and registers the
child's interior subtree key: the reader wakes on any visible change under `detail` — correct,
but coarser than per-member. Binding the child projection first
(`let detail = viewModel.detail`, the `if let` optional idiom, or §6.3's row idiom) picks the
child subscript and keeps per-member granularity and cache-served derived reads.

## 3. Runtime types — full source

New directory `Sources/Lattice/FeatureState/`. These are library types, not macro output; the
macro generates only the four per-type members (§4). `Package.swift` and `Lattice.podspec`
glob `Sources/Lattice/**` — no manifest changes.

### 3.1 `FeatureStateProtocol.swift`

```swift
/// Conformance is generated by the `@FeatureState` macro. Do not conform manually.
public protocol FeatureStateProtocol {
    /// A key-path namespace mirroring the view-visible members of the state type.
    /// Never instantiated; exists so that projections can be indexed with compile-time
    /// member checking that excludes domain-only and private members.
    associatedtype _ViewMembers

    /// Maps a namespace key path to the corresponding key path on the state type.
    /// `@MainActor`: key paths are not `Sendable`, so a stored static map must be isolated
    /// (Swift 6 rejects a nonisolated `static let` of non-Sendable type); every reader
    /// (projection, `_commit`, `_diff`) is already MainActor-confined.
    @MainActor
    static var _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] { get }

    /// The subset of `_ViewMembers` key paths whose members are computed — derived view
    /// output. The projection serves these from the registrar's derivation cache (seeding
    /// on first read); stored members read straight through committed state. Enum case
    /// accessors are deliberately excluded (§4.2): they read through.
    @MainActor
    static var _derivedMembers: Set<PartialKeyPath<_ViewMembers>> { get }

    /// The generated reducer: diff each view-visible member of `old` against `new` and
    /// fire `registrar` for every member whose value or derived output changed.
    /// `key` is the projection-key prefix under which this value lives (root for the
    /// host's own state; extended per member/element when nested).
    /// `@MainActor`: `_commit` talks to the MainActor-confined registrar.
    @MainActor
    static func _commit(
        old: Self, new: Self,
        registrar: FeatureStateRegistrar, key: ProjectionKey
    )
}
```

### 3.2 `ProjectionKey.swift`

```swift
/// Identifies one view-visible slot in a (possibly nested) feature-state tree.
/// Structurally parallel to `GraphPath`, but keyed by projection members rather than
/// interactor-tree position, and extended per collection element.
public struct ProjectionKey: Hashable {
    enum Component: Hashable {
        case member(AnyKeyPath)   // a _ViewMembers key path
        case element(AnyHashable) // an Identifiable element id inside a collection
        case structure            // the slot's shape: optional presence / collection membership+order
    }

    var components: [Component] = []

    public init() {}

    // Public: macro-generated `_commit` bodies in consumer modules build member keys.
    public func appending(_ member: AnyKeyPath) -> Self {
        var copy = self
        copy.components.append(.member(member))
        return copy
    }

    func appending(id: AnyHashable) -> Self {
        var copy = self
        copy.components.append(.element(id))
        return copy
    }

    /// The slot's shape key: fired when the slot's shape changes (optional presence flips,
    /// collection membership/order changes) and never by content changes within the slot —
    /// content fires bubble to ancestors, and a shape key is a sibling of the content keys,
    /// not an ancestor.
    var structure: Self {
        var copy = self
        copy.components.append(.structure)
        return copy
    }

    func hasPrefix(_ prefix: Self) -> Bool {
        components.count >= prefix.components.count
            && zip(components, prefix.components).allSatisfy(==)
    }
}
```

The FNV incremental hash used by `GraphPath` can be ported here if profiling shows key hashing
on the access path matters; the PoC uses synthesized `Hashable`.

### 3.3 `FeatureStateRegistrar.swift`

The per-ViewModel side table: one signal object per accessed key, plus the derivation cache.
A view body that reads a projected member touches that key's signal, which registers with the
Observation framework as usual. Commit collects the keys whose value or output changed and
pokes each signal exactly once at the end of the batch — invalidating exactly the views that
read those members. Nothing about the state value itself is observable.

Keys form a hierarchy, and observation is **two-tier** on that hierarchy:

- the root `ProjectionKey()` is the whole-state slot; interior keys (nested child slots,
  optional-child slots, collection slots) are subtree slots; leaf keys are fine-grained — all
  the same mechanism at different depths;
- **fires bubble up**: when a key fires, every ancestor prefix that has a signal fires too
  (an O(depth) dictionary walk per fired key), so a whole-state or subtree observer wakes on
  any visible change below it — and only on visible changes, because domain-only commits fire
  no keys at all.

```swift
@MainActor
public final class FeatureStateRegistrar {

    /// One signal per accessed projection key. A manual `Observable` conformance over a raw
    /// `ObservationRegistrar`: observation is keyed on (object identity, key path), and the
    /// single anchor key path is the stored `cachedOutput` slot. For derived-member keys the
    /// anchor doubles as the derivation cache; for stored-member, shape, subtree, and root
    /// keys it stays `nil` — the committed state itself is their storage.
    final class Signal: Observable {
        private let registrar = ObservationRegistrar()

        /// Populated for derived members (the member's last committed output); nil for
        /// everything else.
        fileprivate var cachedOutput: Any?

        /// Read side: register observation access on the anchor slot.
        func access() { registrar.access(self, keyPath: \Signal.cachedOutput) }

        /// Notify without storing: the mutation already happened elsewhere (in the
        /// committed state value); this delivers the notification for it.
        fileprivate func fire() {
            registrar.withMutation(of: self, keyPath: \Signal.cachedOutput) {}
        }

        /// Notify and store a derived member's freshly computed output in one mutation.
        fileprivate func fire(storing newOutput: Any) {
            registrar.withMutation(of: self, keyPath: \Signal.cachedOutput) {
                cachedOutput = newOutput
            }
        }
    }

    private var signals: [ProjectionKey: Signal] = [:]

    /// Non-nil while a `commit(_:)` batch is open: the keys to poke at batch close, plus
    /// the fresh outputs to store into derived signals when their poke is delivered.
    private var batch: (fired: Set<ProjectionKey>, outputs: [ProjectionKey: Any])?

    /// Internal test seam: invoked once for every signal poke actually delivered (batched
    /// pokes at batch close, immediate fires otherwise). Test helpers install a closure
    /// here to record fires per commit. (The spec previously sketched a
    /// `RecordingRegistrar` subclass; the class is `final` and batching is private, so a
    /// subclass cannot observe pokes — the seam replaces it.)
    var onPoke: ((ProjectionKey) -> Void)?

    public init() {}

    // MARK: Read side

    /// Register observation access on `key`. Stored-member leaves, shape keys, and
    /// explicitly coarse reads (subtree keys, the root whole-state key) come through here;
    /// the value itself is read straight from committed state by the caller.
    func access(_ key: ProjectionKey) {
        signal(for: key).access()
    }

    /// Read side for derived members: serve the cached output, seeding it on the first
    /// read. Registers access either way. Seeding stores without notifying — nothing
    /// changed; the output was merely never cached.
    func derived<Output>(_ key: ProjectionKey, compute: () -> Output) -> Output {
        let signal = signal(for: key)
        signal.access()
        if let cached = signal.cachedOutput {
            // The generator emits the key and the compute closure for the same member;
            // the cast cannot fail (same argument as the `_viewKeyPaths` casts).
            return cached as! Output
        }
        let fresh = compute()
        signal.cachedOutput = fresh
        return fresh
    }

    // MARK: Commit side

    /// Batch wrapper the host installs around the commit diff. Keys fired inside the body
    /// collect into a set; at close, the set expands with every ancestor prefix that has a
    /// signal (bubbling), and each collected signal is poked exactly once — with its fresh
    /// derived output where one was computed, empty otherwise. The root signal, when one is
    /// registered, is therefore poked exactly when something visible changed; a domain-only
    /// commit pokes nobody.
    func commit(_ body: () -> Void) {
        batch = (fired: [], outputs: [:])
        body()
        let (fired, outputs) = batch!
        batch = nil
        var toPoke: Set<ProjectionKey> = []
        for key in fired {
            toPoke.insert(key)
            var prefix = key
            while !prefix.components.isEmpty {          // O(depth) walk per fired key
                prefix.components.removeLast()
                if signals[prefix] != nil { toPoke.insert(prefix) }
            }
        }
        for key in toPoke {
            guard let signal = signals[key] else { continue }
            if let output = outputs[key] {
                signal.fire(storing: output)
            } else {
                signal.fire()
            }
            onPoke?(key)
        }
    }

    /// Fire one key: a stored member's value changed. Inside a batch, recorded
    /// unconditionally — even when the key itself has never been read — so that registered
    /// ancestors (subtree/root slots) still bubble; outside one (tests, direct use),
    /// delivered immediately to the key's own signal when one exists.
    func invalidate(_ key: ProjectionKey) {
        if batch != nil {
            batch!.fired.insert(key)
        } else if let signal = signals[key] {
            signal.fire()
            onPoke?(key)
        }
    }

    /// Coarse fire: everything at or under `prefix` changed at once (enum case flips,
    /// optional-presence flips). Fires every registered signal under the prefix — the
    /// prefix's own key included — and clears every cached output under it: an output
    /// cached against the departed shape must never be served against the new one. The
    /// next commit (or first read) reseeds and fires conservatively. Inside a batch the
    /// prefix itself is also recorded unconditionally, so registered ancestors bubble even
    /// when nothing under the prefix has been read.
    /// Public: generated enum `_commit` case-flip branches call it from consumer modules.
    /// ponytail: O(#accessed keys) scan; index by first component if profiling demands.
    public func invalidate(prefix: ProjectionKey) {
        if batch != nil { batch!.fired.insert(prefix) }
        for (key, signal) in signals where key.hasPrefix(prefix) {
            signal.cachedOutput = nil
            if batch != nil {
                batch!.fired.insert(key)
            } else {
                signal.fire()
                onPoke?(key)
            }
        }
    }

    /// Commit side for derived members; the generated `_commit` emits one call per
    /// computed member. Three cases:
    /// - no signal for `key` (the member has never been read): `compute` does not run —
    ///   an unobserved derived member costs nothing at commit and contributes nothing to
    ///   coarse fires;
    /// - cached output present: compute once, compare by `==`; on change, fire and store;
    /// - signal present but cache empty (first commit after a coarse drop): compute,
    ///   store, and fire conservatively.
    /// Public: generated `_commit` bodies call it from consumer modules.
    public func commitDerived<Output: Equatable>(_ key: ProjectionKey, _ compute: () -> Output) {
        guard let signal = signals[key] else { return }
        let fresh = compute()
        if let cached = signal.cachedOutput, (cached as! Output) == fresh { return }
        if batch != nil {
            batch!.fired.insert(key)
            batch!.outputs[key] = fresh
        } else {
            signal.fire(storing: fresh)
            onPoke?(key)
        }
    }

    /// Structural pruning: drop every signal — and its cached output — at or under
    /// `prefix`. The collection diff calls this for removed element IDs; a surviving
    /// signal holding a stale cached output would serve wrong UI if the ID returned.
    func removeSignals(prefix: ProjectionKey) {
        for key in signals.keys where key.hasPrefix(prefix) {
            signals.removeValue(forKey: key)
        }
    }

    private func signal(for key: ProjectionKey) -> Signal {
        if let existing = signals[key] { return existing }
        let created = Signal()
        signals[key] = created
        return created
    }
}
```

Notes:

- The signal shape — a real stored anchor that doubles as the per-slot cache, poked with an
  empty `withMutation` when the change lives elsewhere — matches the reference architecture's
  whole-state and per-slot observation mechanics; it leans only on supported Observation API
  (the `Observable` marker protocol plus a raw `ObservationRegistrar`).
- `signals` grows with the set of keys views have actually read — bounded by the visible
  surface actually on screen, plus per-element keys — and with it the derivation cache, one
  retained output per observed derived member. Element keys are pruned via
  `removeSignals(prefix:)` when the collection diff drops their IDs (§3.7) — mandatory, not a
  refinement, because the cache makes stale entries a correctness problem rather than a
  spurious wake.
- Whole-state observation is `access(ProjectionKey())` — the registrar just provides the
  slot; whether and where the ViewModel exposes a whole-state snapshot read is plan 6's call.
- Isolation: `@MainActor` today, matching the ViewModel host. If an off-main host lands later,
  the registrar moves to the same `any Actor` confinement story as `LatticeCore`.

### 3.4 `Diff.swift` — the overload-ranked member diff

The macro emits one `Lattice._diff(...)` call per visible **stored** member. Which diff runs
is decided by **generic overload ranking**, so the macro never needs to know member types
semantically. Computed members do not flow through `_diff` at all: the macro classifies
stored vs computed syntactically and emits `registrar.commitDerived(...)` for computed
members instead (§3.3, §4), so a computed member's body runs at most once per commit and
only when observed.

```swift
// Nested feature state that is also Equatable: cheap whole-value gate, then recurse.
@MainActor
public func _diff<Child: FeatureStateProtocol & Equatable>(
    _ old: Child, _ new: Child,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    guard old != new else { return }
    Child._commit(old: old, new: new, registrar: registrar, key: key)
}

// Nested feature state: delegate to the child's generated commit.
@MainActor
public func _diff<Child: FeatureStateProtocol>(
    _ old: Child, _ new: Child,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    Child._commit(old: old, new: new, registrar: registrar, key: key)
}

// Optional feature state (optional stored members; enum case accessors).
@MainActor
public func _diff<Child: FeatureStateProtocol>(
    _ old: Child?, _ new: Child?,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    switch (old, new) {
    case (nil, nil):
        break
    case (let old?, let new?):
        Child._commit(old: old, new: new, registrar: registrar, key: key)
    default:
        // Presence flipped: everything under this slot changed at once. The prefix fire
        // covers the slot's own key, the shape key, and every registered descendant, and
        // clears the derived caches under the slot.
        registrar.invalidate(prefix: key)
    }
}

// Identified collections of feature states: identity-keyed diff (see CollectionDiff.swift).
@MainActor
public func _diff<Element>(
    _ old: IdentifiedArrayOf<Element>, _ new: IdentifiedArrayOf<Element>,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) where Element: FeatureStateProtocol & Identifiable & Equatable {
    _diffIdentifiedCollection(old, new, registrar: registrar, key: key)
}

// Leaf values: fire when the stored value changed.
// Disfavored so that any of the structure-aware overloads above outranks it when both apply.
@_disfavoredOverload
@MainActor
public func _diff<Value: Equatable>(
    _ old: Value, _ new: Value,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    guard old != new else { return }
    registrar.invalidate(key)
}

// Unsupported: a view-visible member that is not Equatable. Unavailable declarations lose
// overload resolution to available ones, so this only matches when nothing else can — and
// then fails compilation with an actionable message at the expansion site.
@available(
    *, unavailable,
    message: """
        view-visible members must be Equatable — make the type Equatable, \
        mark the member '@Domain', or make it 'private'
        """
)
@MainActor
public func _diff<Value>(
    _ old: Value, _ new: Value,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) { fatalError() }
```

Ranking summary (most to least specific): identified collection → optional child → child +
`Equatable` → child → leaf `Equatable` (disfavored) → unavailable catch-all. Never a naive
whole-enum or whole-collection `==` where structure can do better; never a compile-pass for a
non-`Equatable` visible member. The ranking serves stored members only — computed members are
generated as `commitDerived` calls and diff as leaf values through the cache regardless of
their output type (§7's pinned consequences).

### 3.5 `FeatureProjection.swift`

The read surface. Generic over the state type; per-type shape comes from the generated
`_ViewMembers` namespace, so `@Domain`/private members are unreachable at compile time. The
same overload-ranking trick as `_diff` decides whether a member reads as a value, chains as a
child projection, or exposes a collection projection. Within the leaf subscript,
`_derivedMembers` routes derived members to the registrar's cache (seed-or-serve) and stored
members to a plain read-through.

```swift
@MainActor
@dynamicMemberLookup
public struct FeatureProjection<State: FeatureStateProtocol> {
    let read: () -> State
    let registrar: FeatureStateRegistrar
    let key: ProjectionKey

    // Leaf values: register access, then serve. Derived members come from the registrar's
    // cache (computing and seeding on first read); stored members read through committed
    // state — one key-path read is already minimal, so they have no cache.
    @_disfavoredOverload
    public subscript<Value: Equatable>(
        dynamicMember member: KeyPath<State._ViewMembers, Value>
    ) -> Value {
        let memberKey = key.appending(member)
        // The macro generates both sides of the map; the cast cannot fail.
        let stateKeyPath = State._viewKeyPaths[member] as! KeyPath<State, Value>
        if State._derivedMembers.contains(member) {
            return registrar.derived(memberKey) { read()[keyPath: stateKeyPath] }
        }
        registrar.access(memberKey)
        return read()[keyPath: stateKeyPath]
    }

    // Nested feature states chain as child projections. Note: chaining registers nothing.
    public subscript<Child: FeatureStateProtocol>(
        dynamicMember member: KeyPath<State._ViewMembers, Child>
    ) -> FeatureProjection<Child> {
        let stateKeyPath = State._viewKeyPaths[member] as! KeyPath<State, Child>
        return FeatureProjection<Child>(
            read: { read()[keyPath: stateKeyPath] },
            registrar: registrar,
            key: key.appending(member)
        )
    }

    // Optional feature states (optional stored members; enum case accessors):
    // registers the slot's shape key, then chains when present.
    public subscript<Child: FeatureStateProtocol>(
        dynamicMember member: KeyPath<State._ViewMembers, Child?>
    ) -> FeatureProjection<Child>? {
        let childKey = key.appending(member)
        registrar.access(childKey.structure)   // presence flips fire this; content changes do not
        let stateKeyPath = State._viewKeyPaths[member] as! KeyPath<State, Child?>
        guard read()[keyPath: stateKeyPath] != nil else { return nil }
        return FeatureProjection<Child>(
            read: { read()[keyPath: stateKeyPath]! },
            registrar: registrar,
            key: childKey
        )
    }

    // Identified collections of feature states.
    public subscript<Element>(
        dynamicMember member: KeyPath<State._ViewMembers, IdentifiedArrayOf<Element>>
    ) -> CollectionProjection<Element>
    where Element: FeatureStateProtocol & Identifiable & Equatable {
        let stateKeyPath =
            State._viewKeyPaths[member] as! KeyPath<State, IdentifiedArrayOf<Element>>
        return CollectionProjection(
            read: { read()[keyPath: stateKeyPath] },
            registrar: registrar,
            key: key.appending(member)
        )
    }
}
```

**Chaining and interior keys.** Interior keys (a nested child's slot, an optional child's
slot, a collection's slot) are the coarse subtree slots that fine-grained fires bubble up
to. The child subscripts therefore register nothing, and presence/membership observation
goes through the dedicated **shape key** (`key.structure`), which presence flips and
structural pings fire and which content changes never reach.

**Inline chained reads resolve to the leaf subscript, not the child chain** — a confirmed
constraint-solver scoring consequence, not a tunable ranking: both interpretations of
`projection.child.title` contain exactly one disfavored use (the trailing leaf hop is itself
the disfavored subscript), so the solver tie-breaks on key-path-application count and the
one-lookup raw-value read always beats the two-lookup chain. No `@_disfavoredOverload`
placement changes this. Accepted semantics (supervisor decision, phase A): the leaf
subscript's registered `memberKey` for a feature-typed member *is* the child's interior
subtree key, so inline chained reads degrade to **coarse-but-correct subtree reads** — the
reader wakes on any visible change under the child (fires bubble to the interior key), and
nested derived members read inline compute from committed state, bypassing the derivation
cache. Per-member granularity and cache-served derived reads require **binding the child
projection first** (`let child = projection.child`, the `if let` optional idiom, §6.3's row
idiom), which the solver resolves to the child subscripts. Collection reads
(`projection.items[id:]`, `.ids`) resolve to `CollectionProjection` even inline, because
their trailing hops are real members, not the disfavored leaf subscript.

### 3.6 `CollectionProjection.swift`

```swift
@MainActor
public struct CollectionProjection<Element>
where Element: FeatureStateProtocol & Identifiable & Equatable {
    let read: () -> IdentifiedArrayOf<Element>
    let registrar: FeatureStateRegistrar
    let key: ProjectionKey

    /// Structural reads register the collection's shape key: any insert/remove/reorder
    /// fires it; element content changes do not (they bubble to the collection's own
    /// subtree key, which only explicitly coarse readers register).
    public var ids: OrderedSet<Element.ID> {
        registrar.access(key.structure)
        return read().ids
    }

    public var count: Int {
        registrar.access(key.structure)
        return read().count
    }

    public var isEmpty: Bool {
        registrar.access(key.structure)
        return read().isEmpty
    }

    /// Per-element projection. `nil` when the id is no longer present — row views can be
    /// asked to render transiently after a removal, before the structural ping propagates.
    /// Registers the shape key (membership is shape), never the collection's subtree key.
    public subscript(id id: Element.ID) -> FeatureProjection<Element>? {
        registrar.access(key.structure)
        guard read()[id: id] != nil else { return nil }
        return FeatureProjection<Element>(
            read: { read()[id: id]! },
            registrar: registrar,
            key: key.appending(id: id)
        )
    }
}
```

### 3.7 `CollectionDiff.swift`

The identity-keyed diff — full semantics and the worked example in §6.

```swift
@MainActor
func _diffIdentifiedCollection<Element>(
    _ old: IdentifiedArrayOf<Element>, _ new: IdentifiedArrayOf<Element>,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) where Element: FeatureStateProtocol & Identifiable & Equatable {
    // Structural change (insert/remove/reorder): one ping on the collection's shape key.
    // ForEach identity re-derives; surviving rows are untouched unless they also changed;
    // coarse readers of the collection's own key wake by bubbling.
    if old.ids != new.ids {
        registrar.invalidate(key.structure)
        // Prune the signals — and cached derived outputs — of departed elements. Mandatory:
        // a stale cached output would render wrong UI if the ID returns (a stale wake was
        // merely spurious; a stale cache is incorrect).
        for id in old.ids where new[id: id] == nil {
            registrar.removeSignals(prefix: key.appending(id: id))
        }
    }

    for newElement in new {
        // Inserted elements are covered by the structural ping; their rows render fresh.
        guard let oldElement = old[id: newElement.id] else { continue }
        // The load-bearing gate: unchanged elements cost one == and nothing else.
        guard oldElement != newElement else { continue }
        Element._commit(
            old: oldElement, new: newElement,
            registrar: registrar, key: key.appending(id: newElement.id)
        )
    }
}
```

## 4. Generated code — hand expansions

The macro generates exactly four members per type (plus enum case accessors), all delegating
into §3's library types. These expansions are the normative baseline for the expansion tests
(§11.3); the compile spike (§12) checks them in verbatim before the macro exists.

### 4.1 A representative struct

```swift
@FeatureState
struct SearchState {
    @Domain var rawResults: [SearchResult] = []
    var query: String = ""
    var isLoading: Bool = false
    var subtitle: String {
        "\(rawResults.count) results"
    }
}
```

expands to:

```swift
struct SearchState {
    @Domain var rawResults: [SearchResult] = []
    var query: String = ""
    var isLoading: Bool = false
    var subtitle: String {
        "\(rawResults.count) results"
    }

    struct _ViewMembers {
        let query: String
        let isLoading: Bool
        let subtitle: String
        @available(*, unavailable) private init() {
            fatalError()
        }
    }

    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
        \_ViewMembers.query: \SearchState.query,
        \_ViewMembers.isLoading: \SearchState.isLoading,
        \_ViewMembers.subtitle: \SearchState.subtitle,
    ]

    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
        \_ViewMembers.subtitle,
    ]

    @MainActor static func _commit(
        old: SearchState, new: SearchState,
        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
    ) {
        Lattice._diff(
            old.query, new.query,
            registrar: registrar, key: key.appending(\_ViewMembers.query))
        Lattice._diff(
            old.isLoading, new.isLoading,
            registrar: registrar, key: key.appending(\_ViewMembers.isLoading))
        registrar.commitDerived(key.appending(\_ViewMembers.subtitle)) {
            new.subtitle
        }
    }
}

extension SearchState: Lattice.FeatureStateProtocol {
}
```

Points worth pinning:

- Generated members mirror the type's access level (the same treatment today's
  `ObservableStateMacro` gives its members).
- `key.appending(\_ViewMembers.query)` in `_commit` and the projection subscript's
  `key.appending(member)` produce the **same key** for the same member — the fire side and the
  register side agree by construction.
- The state type itself is untouched: no added stored properties, no `Observable` conformance,
  synthesized `Equatable`/`Codable`/memberwise-init behavior all unchanged.

### 4.2 An enum

Enums get the same treatment plus **case accessors**: for each single-payload case, an optional
computed property named after the case (the `@CasePathable` naming convention). Case accessors
are view-visible members like any other, which gives views compile-checked access to associated
values and gives `_commit` a uniform slot key per case payload.

```swift
@FeatureState
enum RouteState {
    case list
    case detail(DetailState)      // DetailState is itself @FeatureState
    case banner(String)

    var accessibilityLabel: String {
        switch self {
        case .list: "All items"
        case .detail: "Item detail"
        case .banner(let message): message
        }
    }
}
```

expands to:

```swift
enum RouteState {
    case list
    case detail(DetailState)
    case banner(String)

    var accessibilityLabel: String {
        switch self {
        case .list: "All items"
        case .detail: "Item detail"
        case .banner(let message): message
        }
    }

    var detail: DetailState? {
        guard case .detail(let value) = self else {
            return nil
        }
        return value
    }

    var banner: String? {
        guard case .banner(let value) = self else {
            return nil
        }
        return value
    }

    struct _ViewMembers {
        let detail: DetailState?
        let banner: String?
        let accessibilityLabel: String
        @available(*, unavailable) private init() {
            fatalError()
        }
    }

    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
        \_ViewMembers.detail: \RouteState.detail,
        \_ViewMembers.banner: \RouteState.banner,
        \_ViewMembers.accessibilityLabel: \RouteState.accessibilityLabel,
    ]

    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
        \_ViewMembers.accessibilityLabel,
    ]

    @MainActor static func _commit(
        old: RouteState, new: RouteState,
        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
    ) {
        switch (old, new) {
        case (.list, .list):
            break
        case (.detail(let oldValue), .detail(let newValue)):
            Lattice._diff(
                oldValue, newValue,
                registrar: registrar, key: key.appending(\_ViewMembers.detail))
        case (.banner(let oldValue), .banner(let newValue)):
            Lattice._diff(
                oldValue, newValue,
                registrar: registrar, key: key.appending(\_ViewMembers.banner))
        default:
            registrar.invalidate(prefix: key)
            return
        }
        registrar.commitDerived(key.appending(\_ViewMembers.accessibilityLabel)) {
            new.accessibilityLabel
        }
    }
}

extension RouteState: Lattice.FeatureStateProtocol {
}
```

Semantics locked here:

- **Case flip ⇒ one coarse fire** (`invalidate(prefix:)`, which covers the slot's own key,
  its shape key, and every registered descendant — and clears the derived caches under the
  slot). Correct because a case change is a whole-view change; cheap because it is one
  discriminator comparison.
- **Same case ⇒ recurse into the payload**: `_diff` overload ranking sends `@FeatureState`
  payloads through their own `_commit` (granular) and plain `Equatable` payloads through the
  leaf compare (one fire on the case-accessor key). Granularity inside a case therefore comes
  from making the payload `@FeatureState`.
- **Case accessors are computed properties but are not derived members.** Deliberate call:
  their payload diffing stays in the case switch (granular, and it uses the payload values
  already in hand), so they do not go through `commitDerived` and are not listed in
  `_derivedMembers` — the projection reads them through committed state, where extracting a
  payload is one enum match, too cheap to cache; caching them would also fight the case-flip
  cache drop. Ordinary computed members like `accessibilityLabel` **are** derived members.
- View access chains through the optional-child projection subscript:
  `viewModel.route.detail?.title` registers the `detail` slot's shape key (presence) and the
  child's `title` key.
- **Multi-payload cases** (two or more associated values) are not projected in the PoC: the
  macro emits an error directing the payload into a single (ideally `@FeatureState`) struct.
  Tuple `Equatable` conformance would lift this later; tracked as a limitation, not designed
  around.
- `@Domain` on an enum's computed members works as on structs. Cases themselves cannot be
  `@Domain` — the case *is* the domain data; visibility of its payload is controlled by the
  payload type's own annotations.

### 4.3 A collection-bearing parent

```swift
@FeatureState
struct TransactionsState {
    @Domain var account: Account
    @Domain var filter: TransactionFilter = .all
    var transactions: IdentifiedArrayOf<Transaction> = []

    // Collection structure lives on the parent as small derived values.
    var visibleOrder: [Transaction.ID] {
        transactions.elements
            .filter(filter.includes)
            .sorted { $0.postedAt > $1.postedAt }
            .map(\.id)
    }

    var emptyMessage: String? {
        transactions.isEmpty ? "No transactions yet" : nil
    }
}
```

expands to:

```swift
struct TransactionsState {
    // ... original members unchanged ...


    struct _ViewMembers {
        let transactions: IdentifiedArrayOf<Transaction>
        let visibleOrder: [Transaction.ID]
        let emptyMessage: String?
        @available(*, unavailable) private init() {
            fatalError()
        }
    }

    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
        \_ViewMembers.transactions: \TransactionsState.transactions,
        \_ViewMembers.visibleOrder: \TransactionsState.visibleOrder,
        \_ViewMembers.emptyMessage: \TransactionsState.emptyMessage,
    ]

    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
        \_ViewMembers.visibleOrder,
        \_ViewMembers.emptyMessage,
    ]

    @MainActor static func _commit(
        old: TransactionsState, new: TransactionsState,
        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
    ) {
        Lattice._diff(
            old.transactions, new.transactions,
            registrar: registrar, key: key.appending(\_ViewMembers.transactions))
        registrar.commitDerived(key.appending(\_ViewMembers.visibleOrder)) {
            new.visibleOrder
        }
        registrar.commitDerived(key.appending(\_ViewMembers.emptyMessage)) {
            new.emptyMessage
        }
    }
}

extension TransactionsState: Lattice.FeatureStateProtocol {
}
```

`visibleOrder` draws the §8 collection-return warning by design — the message names the
`[ID]` idiom as the accepted shape; there is no suppression mechanism beyond it being a
warning.

Note what the macro did *not* have to know: that `Transaction` is a feature state, that
`IdentifiedArrayOf` is a collection, or what `visibleOrder` costs. Stored members are all the
same `Lattice._diff` and the type system picks the right diff; computed members are classified
syntactically (a getter body is visible in syntax) and become `commitDerived` calls.

## 5. Commit integration — where `_commit` runs

Plan 02 §4 pins the host wiring: the core's single mutation funnel ends in the host-owned
`onCommit` hook. This plan's diff **is** that hook's body — the "reduce + observe" stage that
plan 02 sketched with the ViewStateReducer becomes one generated call:

```swift
// ViewModel init (MainActor): the commit funnel's host stage is one generated call inside
// the registrar's batch, installed alongside the routing closure at mount.
core.mount(
    interact: interactRoute,
    onCommit: { [registrar] oldState, newState in
        registrar.commit {
            State._commit(
                old: oldState, new: newState, registrar: registrar, key: ProjectionKey())
        }
    }
)
```

Consequences, in funnel order (mutate → presence-flip task cancellation → commit):

- `_commit` runs on **every** commit — update phase and effect-phase `modify` alike. There is
  no whole-state equality pre-gate and none is needed: gating is per member, inside the diff.
- **Fires are batched per commit.** Inside `registrar.commit`, changed keys — and, by
  bubbling, every ancestor prefix with a signal — collect into a set; each signal is poked
  exactly once when the batch closes. A whole-state (root-key) observer therefore wakes at
  most once per commit, and only when something visible changed; a domain-only commit wakes
  nobody.
- **Derived members are observer-gated.** `commitDerived` never runs a computed member's body
  unless some view has read it — an unobserved derivation costs zero at commit and
  contributes nothing to coarse fires. Observed derivations run once and diff against the
  cached output.
- The old `.sent`-and-equal skip, the `areStatesEqual` strategies, and the working-copy
  exclusivity dance are all subsumed. The state value that views read is simply the core's
  committed state; the registrar is the only mutable observation artifact, and it lives in the
  host.
- `old` is always available at the funnel (the core holds the pre-mutation value) and the
  derivation cache lives in the host's signals, not in the state value — which is why this
  works for enums, which have no stored slots to hide caches in.
- Ordering with effects: `_commit` fires before the update's effects launch (plan 02 §5), so a
  view invalidated by the synchronous mutation renders from committed state even if an effect
  immediately mutates again — each `modify` is its own funnel pass with its own diff and its
  own batch.

## 6. Collections of features — the centerpiece

### 6.1 Semantics

Elements are `FeatureStateProtocol & Identifiable & Equatable`, stored in `IdentifiedArrayOf`
(swift-identified-collections is already a dependency). The diff (§3.7) has three tiers:

| Change | Cost | Fires |
|---|---|---|
| removed / inserted / reordered IDs | one `OrderedSet ==` | one structural ping on the collection's shape key (`ForEach` identity re-derives; coarse collection observers wake by bubbling); departed IDs' signals and caches are pruned |
| same ID, `old == new` | one element `==` | **nothing** — skipped entirely |
| same ID, changed | element `==` + element `_commit` | only that element's changed member keys, at `(collectionKey, elementID, member)` |

The middle row is the load-bearing gate. A commit that touches something unrelated (a `@Domain`
field, one element out of a thousand) costs one O(n) sweep of `Equatable` compares and **zero
derivation**: no row's computed properties are built, no row view is invalidated. This is what
today's whole-ViewState reducer could never express — it rebuilt every row's view data on every
commit and relied on a single coarse equality gate to skip rendering.

### 6.2 The idiom

- **Per-item rendering instructions** = the element's visible computed properties. The element
  type is the row's view contract.
- **Collection-level structure** (sort order, filtering, grouping) = parent computed properties
  returning **small values**: `[ID]`, section-key arrays, counts. These diff by cheap `==` and
  fire independently of row content.
- **Never a materialized `[RowViewData]`.** A visible computed property that assembles an array
  of per-row view structs recreates the O(n)-derivation-per-commit problem inside the new
  system, defeats the per-element skip, and draws the macro's collection-return warning (§8).

### 6.3 Worked example — rich domain transactions

Domain-heavy element; every stored member is `@Domain`, the view contract is entirely computed:

```swift
@FeatureState
struct Transaction: Identifiable, Equatable {
    let id: TransactionID
    @Domain var amount: Money
    @Domain var merchant: Merchant
    @Domain var status: TransactionStatus
    @Domain var postedAt: Date

    // The row's rendering instructions.
    var title: String { merchant.displayName }
    var amountLabel: String { amount.formatted() }
    var icon: String { status.isPending ? "clock" : merchant.category.symbolName }
    var isFlagged: Bool { status == .flagged }
}
```

`Equatable` is synthesized over all stored members, `@Domain` included — the whole-element
`==` gate must see domain data, otherwise a domain-only change could never surface through the
computed members that read it. `@Domain` members remain plain Swift members, so the parent's
computed properties (`visibleOrder` sorting by `postedAt`) read them freely; only *views* are
fenced out.

The parent is §4.3's `TransactionsState`. The view:

```swift
struct TransactionsView: View {
    let viewModel: ViewModel<TransactionsState, TransactionsAction>

    var body: some View {
        List {
            // Identity from the parent's derived order; fires only when order/membership changes.
            ForEach(viewModel.visibleOrder, id: \.self) { id in
                if let row = viewModel.transactions[id: id] {
                    TransactionRow(row: row)
                }
            }
        }
        .overlay {
            if let message = viewModel.emptyMessage { ContentUnavailableView(message, ...) }
        }
    }
}

struct TransactionRow: View {
    let row: FeatureProjection<Transaction>

    var body: some View {
        HStack {
            Image(systemName: row.icon)
            Text(row.title)
            Spacer()
            Text(row.amountLabel)
                .bold(row.isFlagged)
        }
    }
}
```

Invalidation traces:

- **One transaction is flagged** (`status = .flagged` on element `X`): `ids` unchanged → no
  structural ping. Every other element: one `==`, skipped. Element `X`: `_commit` runs
  `commitDerived` for each of its **observed** derived members, once each: `title` and
  `amountLabel` compute outputs equal to their cached copies → no fire; `icon` and `isFlagged`
  differ → fire and recache `(transactions, X, icon)` and `(transactions, X, isFlagged)`.
  Exactly one `TransactionRow` re-renders; the `List`, the `ForEach`, and 999 sibling rows do
  not.
- **`@Domain` account refresh** with no transaction changes: `_commit` diffs `transactions`
  (one `ids ==`, n element `==`s, zero fires), then `visibleOrder` and `emptyMessage` — each
  computed once against its cached output (equal, no fire), or skipped entirely if no view
  read it. Nothing invalidates.
- **A transaction is deleted**: `ids` differ → structural ping on the `transactions` shape
  key, and the removed element's signals (and cached outputs) are pruned; `visibleOrder`
  computes once, differs from its cache → fires and recaches; `ForEach` re-derives identity,
  removes one row. Surviving rows compare equal and are skipped. The removed row's projection
  returns `nil` if SwiftUI transiently re-asks for it.
- **Sort toggle stored as `@Domain var filter`**: `transactions` untouched (n `==`s, no
  fires); `visibleOrder` computes once, output differs → one fire; rows move without
  re-rendering their content.

### 6.4 What the collection tier deliberately does not do

- No moved-element detection beyond the structural ping — `ForEach` identity already handles
  moves; per-row content keys are position-independent because they are ID-keyed.
- No diffing of collections of non-feature elements: a visible
  `IdentifiedArrayOf<PlainEquatable>` falls to the leaf `==` overload (one coarse fire). That
  is the correct default for small value collections and the macro warns when a *computed*
  member returns one (§8).
- No pagination/windowing awareness. Off-screen rows cost one `==` per commit (their derived
  members are unobserved and never computed); if profiling ever shows that sweep, the fix is
  §7's input-gated skip, not a smarter collection diff.

## 7. Cost model

Derivation ships **cached and observer-gated** — the derivation cache is built from the
start, living in the registrar's signals (§3.3):

- **Unobserved derived member: 0×.** No signal for its key means `commitDerived` never runs
  the body — a computed member nobody has read costs nothing at commit, on every commit.
- **Observed derived member: 1× per commit.** `commitDerived` computes the fresh output once,
  compares against the host-cached copy by `==`, and fires (recaching) only on change.
- **Reads are cache hits.** The projection serves derived members from the cached output,
  seeding it on first read — view-body evaluation never recomputes a derivation that commit
  already computed, and repeated reads within one body cost one dictionary hit plus a cast.
- **Stored members: one `==` per commit, read-through on access.** One key-path read from
  committed state is already minimal; caching it would only add a second copy to keep
  coherent.

Two semantic consequences are pinned, not incidental:

- **A computed member nobody has read is unobservable and free.** It does not run at commit
  and does not contribute to coarse/root fires until a first read seeds its signal. Stored
  members always diff, so coarse observers see all stored changes. This is consistent with
  the observation model: you depend on what you read.
- **Computed members diff as leaf values through the cache.** A computed property returning a
  nested `@FeatureState` type gets one coarse fire when its output changes — no granular
  recursion into its members. Stored members keep granular recursion via `_diff` overload
  ranking; §8 adds a best-effort macro warning for computed members returning
  `@FeatureState`-conforming types.

An expensive aggregation (`var total: Money` over all transactions) therefore costs one build
per commit while something on screen reads it, and nothing at all when nothing does. The
element-as-feature idiom (§6.2) remains the right shape for per-row data — not to avoid
recompute, but to keep the per-element skip and per-row invalidation. Migration-guide
guidance (plan 09): visible computed properties should be reasonable projections of domain
data; moving extreme aggregations into `@Domain` storage updated by the interactor is a
recommendation for pathological cases, not a requirement of the model.

One future rung stays named but not built: **input-gated skip** — statically determine which
stored members a computed property reads and skip its `commitDerived` call when none of them
changed, taking observed derivations from 1× per commit to 1× per relevant commit. Requires
macro-side body analysis (read-set extraction) or declared dependencies; named here so nobody
designs the registrar in a way that precludes it, and otherwise not pursued.

The rejected alternative was eager compute-both derivation — evaluate `body(old)` and
`body(new)` on every commit and compare, no cache, no observer gating — which cost 2× per
derivation per commit plus per-render recompute on reads; `body(old)` is now never evaluated
anywhere.

## 8. Macro diagnostics

Macros see syntax, not types, so diagnostics split into two delivery mechanisms:

**Type-driven (via generated code).** The macro cannot know whether a member is `Equatable`;
the unavailable `_diff` catch-all (§3.4) turns that check into a compile error with the exact
guidance — *"view-visible members must be Equatable — make the type Equatable, mark the member
'@Domain', or make it 'private'"* — surfaced at the expansion site of the offending member's
diff line.

**Syntactic (emitted by the macro).** Best-effort, precise where syntax suffices:

| Condition | Severity | Message shape |
|---|---|---|
| visible computed property whose return type is syntactically `[...]`, `Array<...>`, `Set<...>`, `Dictionary<...>`, `IdentifiedArrayOf<...>` | warning | "returns a collection: derived collections are rebuilt and compared as one leaf value whenever observed at commit — model elements as `@FeatureState` values in an `IdentifiedArrayOf` stored member, return `[ID]`/section keys for structure, or accept the O(n) compare". No suppression mechanism beyond it being a warning; the `[ID]` idiom is named in the message as the accepted shape. |
| ~~visible computed property whose return type is syntactically a `@FeatureState`-annotated type~~ | — | **Not implementable with the attached-macro API; deferred.** Attached macros see only the attached declaration and its lexical context, never file siblings, so "resolvable in the same file" cannot be checked. The semantic consequence (computed members diff as leaf values through the cache, one coarse fire, no granular recursion) is documented in §7 instead. |
| visible computed property referencing another visible computed property, where the reference graph has a cycle (A reads B, B reads A) | warning | "cyclic derived properties will recurse at evaluation; break the cycle or mark one `@Domain`" — non-cyclic cross-reads are allowed and common |
| visible computed property with a setter | error | "view-visible computed properties are get-only; add `@Domain` for interactor-side settable helpers" |
| `@Domain` on a `private` member | warning | redundant; `private` already excludes it |
| `@FeatureState` on a class, actor, or protocol | error | structs and enums only |
| enum case with two or more associated values | error | "wrap the payload in a single struct (annotate it `@FeatureState` for granular observation)" |
| enum case name colliding with an existing member (blocks the case accessor) | error | rename the case or the member |
| zero visible members | warning | every member is `@Domain`/private; the type has no view surface — likely a missing removal of `@FeatureState` |
| visible stored member without an explicit type annotation | error | the macro cannot see inferred types, and `_ViewMembers` needs the member's type — "add one, mark the member '@Domain', or make it 'private'" |

Syntactic scanning of computed bodies (cycle detection, collection returns) is heuristic:
type aliases and helper-function indirection can evade it. Documented as best-effort; the
type-driven checks are the ones that must never pass incorrectly, and they cannot, because
they are the type system.

## 9. Unidirectionality

The projection is a **read surface**, mechanically:

- Every `FeatureProjection`/`CollectionProjection` subscript and the ViewModel's
  `dynamicMember` subscripts are get-only. There is no setter to generate, so there is no
  "write to state from the view" path to police.
- Visible computed properties are get-only by construction (§8's error).
- Views mutate state exclusively by sending events: `sendViewEvent(_:) -> EventTask` survives
  untouched (README contract), and `ViewModelBinding` keeps its event-sending semantics —
  `binding(\.query, event: SearchAction.queryChanged)` reads through the projection (registering
  access like any read) and writes by sending the event through the interactor. Its read
  key path retargets from `KeyPath<ViewState, Value>` to `KeyPath<State._ViewMembers, Value>`;
  the shape and call sites are otherwise unchanged.

## 10. Deletions and replacements

Executed when plan 6 flips the ViewModel host; until then both layers compile side by side.

| Deleted | Replacement |
|---|---|
| `ViewStateReducer` protocol + `ViewStateReducerBuilder` + `BuildViewState` + `AnyViewStateReducer` | generated `_commit(old:new:registrar:key:)` per `@FeatureState` type |
| `@ViewStateReducer` macro + its `initialViewState(for:)` / `DefaultValueProvider` validation | nothing — there is no second state type to seed |
| `areStatesEqual` strategies + the ViewModel init parameters selecting them | per-member output-equality gating inside `_commit` |
| handwritten `ViewState` structs | the visible members of the annotated state type |
| `@ObservableState` macro, `ObservableState` protocol, `ObservableStateID`, `ObservationStateRegistrar`, `_$id` / `_$willModify`, `Sources/LatticeMacros/Plugins/Derived/` | plain value state + `FeatureStateRegistrar` host side table |
| `AreOrderedSetsDuplicates` and related `_$id`-stability helpers for identified collections | identity-keyed collection diff (§3.7) |
| the ViewModel working-copy / exclusivity mutation pattern | direct commit-funnel diff; state is never observable itself |
| `Feature<Action, DomainState, ViewState>` (three-parameter bundle) | narrows to interactor + state type; whether it survives as a two-parameter convenience or dissolves into `ViewModel.init(initialState:interactor:)` is plan 6's call — this plan requires only that reducer and equality-strategy parameters disappear |

## 11. Impact

### 11.1 ViewModel (with plan 6)

The slimmed host, shape only (plan 6 owns the file):

```swift
@MainActor
@dynamicMemberLookup
public final class ViewModel<State: FeatureStateProtocol, Action> {
    private let core: LatticeCore<State, Action>
    private let registrar = FeatureStateRegistrar()

    public init(initialState: State, interactor: some Interactor<State, Action>) {
        core = LatticeCore(initialState: initialState, isolation: MainActor.shared)
        // ... interactor tree walk builds the routing closure ...
        core.mount(
            interact: interactRoute,
            onCommit: { [registrar] old, new in
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

    // Root lookups mirror FeatureProjection's overload set (leaf / child / optional child /
    // collection) and delegate to it.
    @_disfavoredOverload
    public subscript<Value: Equatable>(
        dynamicMember member: KeyPath<State._ViewMembers, Value>
    ) -> Value { projection[dynamicMember: member] }

    public subscript<Child: FeatureStateProtocol>(
        dynamicMember member: KeyPath<State._ViewMembers, Child>
    ) -> FeatureProjection<Child> { projection[dynamicMember: member] }

    // ... optional-child and collection overloads identically ...

    @discardableResult
    public func sendViewEvent(_ event: Action) -> EventTask {
        EventTask(rawValue: (try? core.send(event)) ?? nil)
    }
}
```

Gone from today's ViewModel: the `Feature` bundle, the reducer property, the `viewState`
stored property and its working copy, `areStatesEqual` plumbing, and every `Sendable`
constraint. The ViewModel owns exactly: core, registrar, projection, event sending.

### 11.2 Testing (with plan 7)

- **Domain assertions are unchanged in spirit**: plan 7's snapshot-diff `TestViewModel` asserts
  committed domain state; nothing in this plan touches that path (`_commit` never mutates
  state — it reads two snapshots and talks to the registrar — and can even be left unwired in
  domain tests).
- **View assertions read the projection**: `#expect(viewModel.subtitle == "3 results")` — same
  reads a view performs, compile-checked against the visible surface, no ViewState fixture
  construction.
- **Granularity assertions** become possible for the first time: the registrar's internal
  `onPoke` test seam records the `ProjectionKey`s poked per commit, so tests can pin
  "flagging one transaction fires exactly `(transactions, X, icon)` and
  `(transactions, X, isFlagged)`". (The earlier `RecordingRegistrar` subclass sketch is not
  implementable: the class is `final` and batching is private, so a subclass cannot observe
  pokes; the seam replaces it.) The library's own §12 gate tests use this; whether a
  consumer-facing recording helper ships in `Sources/Lattice/Testing` is a plan 7 call.
- **Cache and gating assertions** join them, against the same seam:
  - *cache correctness*: after every commit, each observed derived member's cached output
    equals a fresh computation from committed state — gated by a randomized mutation-sequence
    test (§12);
  - *single compute*: a side-effect counter inside a computed member's body asserts exactly
    one evaluation per commit while observed;
  - *observer-gated skip*: the counter stays at zero across commits when no read has seeded
    the member's signal;
  - *coarse drop*: a presence/case flip clears cached outputs under the prefix, and the next
    commit recomputes, reseeds, and fires conservatively;
  - *element pruning*: a removed ID's signals and cached outputs are gone after the
    structural diff;
  - *batch dedupe*: each signal is poked exactly once per commit, ancestors included;
  - *root slot*: the root key fires iff the commit changed something visible;
  - *bound chaining registers leaf-only*: reading `title` through a bound child projection
    registers the leaf (and, for optional children, the shape key) but never the interior
    subtree keys; an *inline* chained read registers exactly the interior subtree key
    (coarse-but-correct, §3.5).
- **Deleted from test surface**: reducer unit tests as a category (there is no reducer type),
  `initialViewState` fixtures, `areStatesEqual` init parameters on harnesses.

### 11.3 Macros workstream (feeds plan 8)

This is now the real macro work in the rework — plan 8's audit of existing macros stays
near-zero, but this plan adds:

- `Sources/LatticeMacros/Plugins/FeatureStateMacro.swift` — member + extension macro:
  visibility classification (skip `@Domain`, `private`, static members) and stored-vs-computed
  classification (syntactic: a getter body), `_ViewMembers` + `_viewKeyPaths` +
  `_derivedMembers` + `_commit` emission for structs (stored members as `_diff` calls,
  computed members as `commitDerived` calls); case-accessor + case-switch emission for
  enums; the §8 syntactic diagnostics. Substantially simpler than the `ObservableStateMacro`
  it replaces (no accessor rewriting, no `_$id` threading, no `willSet` synthesis — output is
  four declarative members).
- `Sources/LatticeMacros/Plugins/DomainMacro.swift` — empty peer expansion.
- Registration in `Plugins/Plugin.swift`; deletion of `Plugins/Derived/ObservableStateMacro.swift`
  and `Plugins/ViewStateReducerMacro.swift` per §10.
- **Expansion-test strategy**: `Tests/LatticeMacrosTests/FeatureStateMacroTests.swift` using
  `assertMacroExpansion` with §4's hand expansions as the checked-in baselines — one test per
  §4 example, plus one per diagnostic row in §8's table. Baselines are exact-match; any
  expansion change is a reviewed diff.
- Macro-binary policy unchanged (plan 01): consumers build from source / CocoaPods
  `prepare_command`; nothing checked in.

### 11.4 Migration (feeds plan 9)

Full before/after for the migration guide. Before — four artifacts:

```swift
struct SearchDomainState {
    var rawResults: [SearchResult] = []
    var query: String = ""
    var isLoading: Bool = false
}

@ObservableState
struct SearchViewState: DefaultValueProvider, Equatable {
    var query: String = ""
    var isLoading: Bool = false
    var subtitle: String = ""
    static let defaultValue = Self()
}

@ViewStateReducer<SearchDomainState, SearchViewState>
struct SearchViewStateReducer: Sendable {
    var body: some ViewStateReducerOf<Self> {
        BuildViewState { domain, view in
            view.query = domain.query
            view.isLoading = domain.isLoading
            view.subtitle = "\(domain.rawResults.count) results"
        }
    }
}

let viewModel = ViewModel(
    initialDomainState: SearchDomainState(),
    feature: Feature(interactor: SearchInteractor(), reducer: SearchViewStateReducer()),
    areStatesEqual: .equatable
)
```

After — one:

```swift
@FeatureState
struct SearchState {
    @Domain var rawResults: [SearchResult] = []
    var query: String = ""
    var isLoading: Bool = false
    var subtitle: String { "\(rawResults.count) results" }
}

let viewModel = ViewModel(initialState: SearchState(), interactor: SearchInteractor())
```

Mechanical recipe: (1) for each ViewState property copied verbatim from domain state, delete
it — the domain property is already visible; (2) for each property *computed* in the reducer,
move the expression into a visible computed property; (3) mark every remaining domain-only
member `@Domain`; (4) delete ViewState, reducer, `Feature` bundling, `areStatesEqual`; (5) view
code is usually untouched — the visible member names were the ViewState's names.

### 11.5 SwiftUI integration

- Views hold the `ViewModel` plainly (`let viewModel:`); no `@Bindable`/`@State` observation
  wrapper is required, because observation attaches to the registrar's signal objects —
  `Observable` conformances whose registrar-mediated access SwiftUI's body-evaluation
  tracking picks up as usual. `withObservationTracking`
  works identically for non-SwiftUI observers.
- Access registration is exact: a body that reads `viewModel.subtitle` re-evaluates only when
  `subtitle`'s output changes, and the read is served from the derivation cache. Unread
  members cost nothing — unread computed members are not even computed at commit.
- Per-element `ForEach` invalidation is §6.3's trace: identity from a parent `[ID]` member,
  row content from element projections, one row re-render per changed element.
- Autocomplete: `viewModel.` completes against the `dynamicMember` subscripts' `_ViewMembers`
  key paths — Xcode surfaces the visible member names. `@Domain` access fails with a standard
  "has no member" diagnostic. Ergonomics validated in the §12 spike (risk §13).

## 12. Phasing and acceptance gates

Phases within this workstream (plans 1–2 assumed landed for phase C only; A and B are
independent of the new core):

**Phase A — runtime + compile spike.** Land §3's library types plus a *hand-expanded* copy of
§4's three examples (struct, enum, collection parent) in a test target, wired to a stub host
(a bare `FeatureStateRegistrar` + closure-held state; no `LatticeCore` needed). Proves:
overload ranking resolves as designed (collection > optional child > child > leaf > unavailable),
projection chaining and compile-time `@Domain` fencing work, `_viewKeyPaths` casts hold, and
the unavailable-overload diagnostic fires with the intended message on a non-`Equatable`
visible member (checked as a deliberate `-verify`-style negative in a fixture, or a commented
compile-fail fixture executed by CI script).

Gate A:
```bash
swift build
swift test --filter FeatureStateRuntimeTests   # hand-expansion granularity + diff-tier tests
```
`FeatureStateRuntimeTests` must include, minimum: leaf fire/skip; computed output-equality
gating (input changed, output identical ⇒ no fire); observer-gated skip (unobserved computed
member never evaluated — side-effect counter at zero); single compute (exactly one evaluation
per commit while observed); cache correctness (cached output equals fresh computation after
every commit, including a randomized mutation-sequence gate); reads served from the cache
(seed on first read, no recompute per read); coarse drop clears caches under the prefix and
the next commit fires conservatively; element-signal pruning on removal; batch dedupe (each
signal poked once per commit); root slot fires iff the commit changed something visible;
bound chaining registers leaf/shape keys only while inline chained reads register the coarse
subtree key (§3.5); nested delegation; optional presence flip
⇒ prefix fire; enum case flip ⇒ coarse, same-case ⇒ granular; every row of §6.1's table via
the registrar's `onPoke` recording seam.

**Phase B — the macro.** Implement `FeatureStateMacro`/`DomainMacro`, replace phase A's
hand expansions with real annotations, land the expansion baselines and diagnostic tests.

Gate B:
```bash
swift test --filter FeatureStateMacroTests     # expansion baselines == §4, all §8 diagnostics
swift test --filter FeatureStateRuntimeTests   # unchanged behavior through real expansion
```

**Phase C — host integration + deletion (with plans 6/7).** Wire `onCommit`, rewrite
`ViewModel`, retarget `ViewModelBinding`, execute §10's deletion table, migrate
`ExampleProject`.

Gate C:
```bash
swift build && swift test                       # zero references to deleted symbols
grep -rn "ViewStateReducer\|ObservableState\|areStatesEqual" Sources/ && exit 1 || true
```
plus a manual ExampleProject pass exercising a collection screen for per-row invalidation
(Instruments' SwiftUI view-body counts or `_printChanges`).

## 13. Risks

| Risk | Notes / mitigation |
|---|---|
| **Enum macro complexity** | Case accessors, payload-count limits, name collisions, and the case-identity switch are the bulk of the macro's branching. Mitigated by the hard PoC limits (single-payload cases only, error otherwise) and exact-match expansion baselines; the enum path is phase-B's largest test surface. |
| **Key-path identity for registrar keying** | Keys are `AnyKeyPath`s to `_ViewMembers` stored members — synthesized-property key paths, where `==`/`hashValue` are reliable. The one soft spot is `_viewKeyPaths` values for *computed* state members (used only via the map's force-cast, not as hash keys). Spike A asserts round-tripping for every member kind. If a toolchain regression ever breaks key-path hashing, the fallback is macro-emitted stable member-name strings as key components — mechanical change, same shapes. |
| **Cache/state divergence** | The top correctness risk of this design: the registrar's cached derived outputs must always equal a fresh computation from committed state, across coarse drops, reseeds, pruning, and read-side seeding races. A wrong cache renders wrong UI silently. Mitigated by the randomized mutation-sequence gate (§11.2/§12): after every commit in a random walk of mutations, every observed derived member's cache is compared against a fresh compute. |
| **Observation framework interop** | The signal design leans on the `Observable` marker conformance plus a raw `ObservationRegistrar` keyed on (object identity, key path) — supported API, and the same per-slot notification shape the reference architecture uses. Risks: signal-table growth for long-lived element churn (bounded by the mandatory `removeSignals(prefix:)` pruning on structural diffs), and MainActor confinement of the registrar (matches the host; revisit with any off-main tier). |
| **Any-cast discipline on the hot read path** | `derived(_:compute:)` and `commitDerived` cast the cached `Any?` to the member's output type on every hit. Safe by construction — the generator emits the key and the typed closure for the same member, so the stored value's type is pinned at the only write sites — the same argument that already covers the `_viewKeyPaths` force-casts. Spike A asserts round-tripping per member kind; a mismatch is a generator bug, caught by the expansion baselines. |
| **Host memory scales with on-screen derived output** | The registrar now retains one copy of each observed derived member's last output, for as long as its signal lives. Bounded by the visible surface (plus per-element keys, pruned on removal), but a huge derived value read once stays resident. Guidance: derived members return small view-shaped values (§6.2); the §8 collection-return warning catches the common offender. |
| **Bubbling walk cost** | Every fired key walks its ancestor prefixes — O(depth) dictionary lookups per fired key, deduped into the batch set. Depth is bounded by state nesting (shallow in practice); the batched poke keeps total notifications at one per signal per commit. If profiling ever shows the walk, precomputing ancestor chains per key is a mechanical internal change. |
| **`@dynamicMemberLookup` ergonomics** | Autocomplete and diagnostics depend on Xcode's handling of `dynamicMember` key-path subscripts. **Phase A confirmed one misranking that no `@_disfavoredOverload` placement can fix**: inline chained reads (`projection.child.title`) resolve to the leaf subscript because both interpretations carry one disfavored use and the solver tie-breaks on key-path-application count. Resolved (supervisor decision) by accepting coarse-but-correct interior-key registration for inline chains and documenting the bind-first idiom for per-member granularity (§3.5); single-hop, bound, and collection reads resolve as designed — spike A pins every ranking pair with a test. |
| **O(n) Equatable sweeps on large collections** | Every commit pays one `==` per element. That is the deliberate price of the skip gate and is cheap for value elements; a pathological element (huge blobs in `@Domain` storage) makes `==` itself expensive. Guidance: keep heavy blobs behind references or IDs. Escalation path is §7's input-gated skip, not a collection redesign. |
| **Transient row access after removal** | `CollectionProjection`'s `subscript(id:)` returns `nil` for removed IDs; a row view's *captured* `FeatureProjection` read closure force-unwraps. Views built on §6.2's idiom (identity and projections derived in the same body pass) never hold one across a removal; the migration guide documents the idiom as the contract. If field reports say otherwise, the read closure changes to cache-last-value — internal change. |
| **Silent visibility mistakes** | Forgetting `@Domain` leaks a member into the view surface (and requires it be `Equatable`). No unsafe behavior — just a wider surface — and the non-`Equatable` error catches many cases incidentally. The zero-visible-members warning covers the inverse. Naming/lint conventions are a docs concern (plan 9). |

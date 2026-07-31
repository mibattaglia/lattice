# Sendable Removal & Imperative Effect Runtime

A ground-up rework of Lattice's domain runtime, inspired by TCA26 (`ComposableArchitecture2`,
reference checkout: `/Users/michaelbattaglia/Documents/pointfree/TCA26`). Three goals:

1. **Drop `Sendable` requirements on all library and consumer types.** The feature tree lives in
   one isolation domain (MainActor via `ViewModel` today; carried internally as `any Actor` so an
   off-main `StoreActor`-style host can be added later, iOS 26+). Effects launch synchronously
   in-domain, so non-Sendable state never crosses an isolation boundary.
2. **Kill the action ping-pong.** `Emission` is deleted. Effects are imperative tasks launched
   during a synchronous update phase and re-enter via direct state mutation (`modify`), not by
   sending follow-up actions.
3. **Keep Lattice's identity.** `interact` stays. `InteractorBuilder`/`When`/`Merge` composition
   stays (static tree). The domain-state → view-state split stays, expressed as a **single
   annotated state type**: `@FeatureState` with `@Domain`-marked interactor-only members and a
   generated view projection. Derivation and observation happen by diffing at commit — there is
   no separate ViewState type, reducer type, or `@ObservableState` machinery.

## Decisions of record

- Keep `interact` (no TCA-style `body`/`Update`). Composition tree is **static**, built once.
- No dynamic body re-evaluation now; it is a *future* direction, so the runtime must not paint
  over it: path-keyed task storage and commit hooks are designed as the substrate remount lands
  on later.
- **The view-state layer is flattened into the state type** (plan 05): `@FeatureState` +
  `@Domain`, uniform visibility rule, diff-at-commit with output-equality gating, host-owned
  registrar. ViewStateReducer, `ViewState` structs, and `@ObservableState` are deleted.
- Derivation is observer-gated and cached: visible computed members evaluate at most once per
  commit against a host-side cached output, and never run when unobserved; the registrar owns
  both the signals and the derivation cache.
- Debounce as a first-class API is deferred; per-call-site task auto-replacement covers the
  common cases. (`Emission.debounce`, `Interactors.Debounce`, `Debouncer` are deleted.)
- Testing moves to snapshot-diff assertions (TCA26 `TestCore` style). No shims for old tests.
- No swift-dependencies integration.
- Swift tools 6.2 floor; iOS 17+ stays the deployment floor (off-main hosting is a later,
  iOS 26-gated tier).

## Pinned shared design contract

Every plan in this directory must conform to these shapes. Change them only by updating this
README first.

### Interactor

```swift
public protocol Interactor<DomainState, Action> {
  associatedtype DomainState   // no Sendable
  associatedtype Action        // no Sendable
  associatedtype Body: Interactor

  /// Static composition via InteractorBuilder.
  /// Evaluated once during tree construction; never re-evaluated.
  @InteractorBuilder<DomainState, Action>
  var body: Body { get }

  func interact(state: inout DomainState, action: Action, effects: Effects<DomainState, Action>)
}
```

`interact` is synchronous, returns `Void`, and runs in the host's isolation domain. As today,
a default `interact` implementation forwards to `body`, and leaf interactors (e.g. `Interact`)
implement `interact` directly with `Body == Never`-style opt-out. Custom `interact`
implementations take precedence over `body`.

### Effects handle

`interact` receives an update-phase handle `Effects<DomainState, Action>` exposing **only**
`perform` (`noasync`). The effect closure receives an effect-phase handle
`EffectState<DomainState, Action>` — passed as the closure's parameter — exposing `modify`, `send`,
`state`, and a writable dynamic-member subscript for one-line field updates. Sending or modifying
from inside `interact` is a **compile-time** error (the update-phase handle has no such
members), not a runtime trap. The core's runtime preconditions remain as a backstop for handles
smuggled across phases and for genuine exclusivity violations (reentrant `modify`), where a
named trap replaces Swift's opaque dynamic-exclusivity crash.

```swift
public struct Effects<DomainState, Action> {   // update-phase handle; non-Sendable, carries GraphPath + core ref
  // Update phase only (noasync):
  public func perform(
    id: EffectID? = nil,
    _ operation: @escaping (EffectState<DomainState, Action>) async throws -> Void
  )  // auto-replaces the in-flight task at the same (path, perform call site); noasync
}

@dynamicMemberLookup
public struct EffectState<DomainState, Action> {  // effect-phase handle; non-Sendable, same weak core + pullback
  public func modify(_ mutate: (inout DomainState) -> Void) throws  // throws CancellationError post-dismount
  @discardableResult
  public func send(_ action: Action) throws -> Task<Void, Never>?    // optional re-entry, never required;
                                                                     // returns that send's own composite effect task (nil if none)
  public var state: DomainState { get }                              // read current state

  // Writable sugar: `effectState.x = v` runs one full commit funnel pass, equivalent to
  // `try? modify { $0.x = v }`. Reads route through the same committed-state read as `state`.
  public subscript<Value>(dynamicMember keyPath: WritableKeyPath<DomainState, Value>) -> Value { get set }
}
```

The canonical idiom passes the `EffectState` handle into the closure:

```swift
effects.perform { effectState in
    let result = try await api.fetch()
    try effectState.modify { $0.result = result }
}
```

The dynamic-member subscript is sugar for the single-field case: `effects.perform { $0.x = v }`
reads as a plain assignment and is equivalent to `effects.perform { effectState in try? effectState.modify { $0.x = v } }`.
Each subscript write is **one full funnel pass** (mutate → transition detection → projection
diff); several assignments made this way are several separate commits — use `modify` when
multiple fields must change atomically in one commit. The subscript accessors cannot throw: a
write after dismount (or once a scoped handle's case has departed) is dropped silently,
consistent with the pinned departed-scope drop semantics below — `modify` remains the throwing
spelling for code that wants to observe cancellation.

- `perform` operations are non-`@Sendable`, launched in-domain via `Task.immediate` (OS 26) /
  `Task.startOnMainActor` shim (iOS 17–25), `@_inheritActorContext(always)`,
  `nonisolated(unsafe)` capture justified by single-call + in-domain start.
- Streams: `effects.perform { effectState in for await x in stream { effectState.latest = x } }` — no
  separate observe primitive.
- CPU-bound work escapes via consumer-side `@concurrent` functions with `sending` values;
  document, don't wrap.
- `EffectID` is the `StoreTaskID` analog: `@EffectID var refresh` — explicit cancel/await/isRunning.

### Structural identity

```swift
public struct GraphPath: Hashable {  // components + incremental FNV hash
  enum Component: Hashable { case keyPath(AnyKeyPath), id(AnyHashable) }
}
```

- `When` appends its state keypath / case-path id; builder blocks append positional index;
  `buildEither` appends a branch tag; `Interact` is a leaf.
- Static tree ⇒ paths computable once at ViewModel init; no caching layer, no remount machinery.

### Feature state & view projection

```swift
@FeatureState
struct SearchState {
  @Domain var rawResults: [SearchResult]     // interactor-only: invisible to views, never diffed
  var query: String                          // view-visible: projected, diffed by == at commit
  var subtitle: String {                     // computed & visible: derived view output,
    "\(rawResults.count) results"            //   diffed by == of its output at commit
  }
}
```

- **Uniform visibility rule**: every member is view-visible unless marked `@Domain` or
  `private`. Two annotations total (`@FeatureState`, `@Domain`); there is no `@Reduced` —
  visible computed properties are derived view output by definition.
- All view-visible members (stored and computed) require `Equatable` (macro-enforced
  diagnostic).
- `@FeatureState` generates four members: the `_ViewMembers` key-path namespace and
  `_viewKeyPaths` map behind the view **projection** (compile-time access control — only
  non-`@Domain`, non-private members exposed; `ViewModel` is `@dynamicMemberLookup` over it),
  the `_derivedMembers` set (which visible members are computed), and the **commit diff**
  `_commit(old:new:registrar:key:)` — fire the host-owned registrar only for members whose
  value (stored) or output (computed) actually changed (the `key` parameter composes registrar
  keying through nesting/elements; the root call passes `ProjectionKey()`, which doubles as
  the registrar's whole-state observation slot).
- **State stays a plain value**: no embedded registrars, no `_$id`, no copy-identity machinery.
  The registrar is a per-ViewModel side table keyed by projection key path; nothing fires at
  `willSet` — all notification is diff-at-commit, so mutation needs no working-copy dance.
- **Nesting recurses**: members whose type is itself `@FeatureState` delegate to that type's
  `_commit` (generic-overload ranking, no annotation) and project as the child's projection.
- **Enums**: case flip ⇒ one coarse fire (correct — whole-view change); same case ⇒ recurse
  into associated values. Granularity inside a case comes from `@FeatureState` associated
  values.
- **Collections of features** (`Identifiable + Equatable` elements, e.g. `IdentifiedArrayOf`):
  identity-keyed diff; `old == new` elements are skipped entirely; only changed elements run
  their `_commit`. Per-element rendering data = the element's visible computed properties;
  collection-level structure (sort/filter/group) = parent computed properties returning small
  values (`[ID]`, section keys).
- Computed members are **derived view output**: evaluated at most once per commit against a
  host-side cached output owned by the registrar, skipped entirely when no view has read
  them, and served from that cache on reads. Fine-grained fires bubble up the key hierarchy,
  so the root whole-state slot (and any interior subtree slot) supports coarse observation
  with the same mechanism.

### Core runtime commit path

Single funnel for **all** mutations (update phase and `modify` alike):

```
mutate domain state
  → transition detection: each When/scoped node whose state presence flipped
    (case left / optional nil'd) cancels its path-prefix task bucket
  → projection diff: `_commit(old:new:registrar:)` fires the host-owned registrar for
    view-visible members whose value/output changed (output-equality gating)
```

Task storage: `[GraphPath: [Location: Task<Void, Never>]]` where `Location` is the `perform`
call site (or `EffectID` identity). First `perform` for a location during one update **replaces**
the previous task; subsequent `perform`s in the same update **track** alongside.

`EventTask` covers the effects launched directly by its send (a composite task over them);
a re-entrant `effectState.send` starts an independent unit with its own returned task.

Phase discipline is enforced first by type — the update-phase `Effects` handle has no
`modify`/`send`/`state`, the effect-phase `EffectState` handle has no `perform` — so cross-phase
misuse fails to compile. The core keeps loud runtime preconditions (TCA26 wording as reference)
as a backstop for handles smuggled across phases and for exclusivity violations:
- `perform` is `@available(*, noasync)` and only legal while `updateContext != nil`.
- `modify` / `send` precondition `updateContext == nil`.

### Scoping semantics

`When` pulls the handle back through (WritableKeyPath, CaseKeyPath) lenses. **If the parent's
enum has left the child's case (or optional is nil) when a child effect calls `modify`, the
mutation is dropped silently and the effect's tasks are cancelled.** This is a documented,
tested contract — the navigation-dismissed-mid-request case.

### What is deleted

`Emission` (+ `Emission+Debounce`), `Debouncer`, `DebounceResult`, `Interactors.Debounce`,
`Send`, `DynamicState`, `UncheckedSendable`, `UncheckedSendableInteractor`,
`uncheckedSendable()`, `eraseToAnyInteractorUnchecked()`, `EmissionExecution`, `ApplyAction`,
`RootScopeState`/`RootScopeTasks`, `EffectTaskRegistry`, `EffectCancellationRegistry`,
`BufferedAction`, every `@unchecked Sendable` conformance, every `Sendable` constraint on
public generics. **From the view-state layer** (plan 05): `ViewStateReducer` protocol +
builder + `BuildViewState` + `AnyViewStateReducer`, `initialViewState(for:)`/
`DefaultValueProvider` validation, `areStatesEqual` strategies, handwritten `ViewState`
structs, the `@ObservableState` macro + `ObservationStateRegistrar` copy-identity machinery.

### What survives untouched

`TestClock`, view-layer API shape (`sendViewEvent(_:) -> EventTask`).

## Plans

| # | File | Workstream | Size |
|---|------|-----------|------|
| 1 | `01-toolchain.md` | Swift 6.2 floor, upcoming features, podspec, macro-binary policy (never checked in) | S |
| 2 | `02-core-runtime.md` | New core: state + path-keyed task storage, commit funnel, phase discipline, in-domain task launch | L |
| 3 | `03-effects-handle.md` | `Effects` public API, `EffectID`, cancellation semantics, scoping pullback | M |
| 4 | `04-interactor-combinators.md` | `interact` signature, builder/When/Merge/Interact rewrite, deletions | M |
| 5 | `05-feature-state.md` | `@FeatureState`/`@Domain` flattening: uniform visibility rule, projection, diff-at-commit, host registrar, element-as-feature collections; replaces the ViewStateReducer layer and `@ObservableState` | L |
| 6 | `06-viewmodel.md` | ViewModel as thin core host, EventTask quiescence, ScopedViewModel | M |
| 7 | `07-testing.md` | Shared core with test commit strategy, snapshot-diff TestViewModel, harness rewrite | L |
| 8 | `08-macros.md` | Macro impact audit (near-zero); no binary workflow — consumer-generated | S |
| 9 | `09-docs-release.md` | README/skills/ExampleProject rewrite, major version, podspec, migration guide | M |
| 10 | `10-dynamic-body.md` | **Optional/future** — dynamic body re-evaluation with full graph support (state-dependent composition, mount/dismount lifecycle, forEach, per-property domain observation). Out of scope for 1.0; layered on plan 02 §11's seams. | XL (future) |

Dependency order: 1 → 2 → (3 + 4) → 5 → 6 → 7 → (8 + 9); 5 lands with 6 (it defines what the
ViewModel hosts) and feeds 8's macro workstream. Plans 2, 5, and 7 are the load-bearing ones.
Execution order and branch strategy: see `orchestration.md` (sequential, stacked branches,
09 at the tip).
Plan 10 is not in the 1.0 dependency graph; adopting it later requires amending this README first.

## Reference material

- TCA26 source: `/Users/michaelbattaglia/Documents/pointfree/TCA26/Sources/ComposableArchitecture2`
  — key files: `Internal/Core.swift`, `Internal/Task.swift`, `Internal/StartOnMainActor.swift`,
  `FeatureDynamicProperties/FeatureStore.swift`, `StoreTaskID.swift`, `Feature.swift`
  (`_GraphPath`), `Testing/TestCore.swift`, `Testing/TestStore.swift`,
  `Documentation.docc/Articles/FeatureFundamentals/FeatureFundamentals-Isolation.md`.
- Investigation briefs: `.pi-subagents/artifacts/78333cc4_scout_0_output.md` (TCA26 isolation),
  `78333cc4_scout_1_output.md` (TCA26 effects/runtime), `78333cc4_scout_2_output.md`
  (Lattice current-state audit).
- Current Lattice runtime to be replaced: `Sources/Lattice/Internal/` and
  `Sources/Lattice/Domain/`.

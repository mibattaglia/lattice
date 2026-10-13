# Identity-Preserving Assignment for `@FeatureState` Members

Status: ✅ Implemented (minimal, source- and behavior-compatible). Updated for the
[unified feature state](./plans/unified-feature-state.md): the overload is constrained on
`FeatureState` (the protocol this spec originally targeted was renamed), assignments come from
the interactor, and the view model applies the same rule to the root state (see "Root
replacement" below).

## Problem

Every `@FeatureState` value carries a macro-synthesized, `@ObservationStateIgnored`
`ObservationStateRegistrar`. `ObservationStateRegistrar.init()` eagerly mints **both** a
fresh `ObservableStateID` (new `UUID`) **and** a fresh `Observation.ObservationRegistrar`
on *every construction*:

```swift
// Sources/Lattice/Observation/ObservationStateRegistrar.swift
public struct ObservationStateRegistrar: Sendable {
    public private(set) var id = ObservableStateID()
    @usableFromInline
    let registrar = ObservationRegistrar()
    public init() {}
    public mutating func _$willModify() { self.id._$willModify() }
}
```

So *mutating* a value carries identity forward, but *constructing* one mints new identity.
An interactor that rebuilds a nested `@FeatureState` member wholesale instead of mutating it —

```swift
Interact { state, event in
    state.child = TimerChildState(value: state.displayedValue)   // wholesale rebuild every tick
    return .none
}
```

— hit the silent branch of `ObservationStateRegistrar.mutate`:

```swift
// before this fix
if isIdentityEqual(value, newValue) || !shouldNotifyObservers(value, newValue) {
    value = newValue          // <-- content-equal Equatable rebuild: adopts a FRESH registrar
} else {                      //     instance with NO withMutation -> SwiftUI never re-accesses
    self.registrar.withMutation(of: subject, keyPath: keyPath) { value = newValue }
}
```

For a content-equal `Equatable` child: `isIdentityEqual == false` (fresh `_$id`),
`shouldNotifyObservers == false` (equal). The first branch silently installed a new
`ObservationRegistrar` instance. SwiftUI's active `ObservationTracking` still retained the
*previous* registrar context (to call `cancel` later) but no mutation ever fired for that
subtree, so it was never reused or released. New contexts accumulated — the measured
~18 registrars/s ≈ 44 MB/hr.

Wholesale rebuild is an idiomatic way to derive a child from other data, so this was not
consumer misuse — it was a silent, unbounded production leak triggered by reasonable code.

## Scope of the leak

The leak is **entirely** the content-equal silent registrar swap (the first branch above).
The content-*changed* branch already fires `withMutation`, so SwiftUI re-accesses the subtree,
re-establishes tracking on the new registrars, and releases the old ones. That branch never
leaked. Therefore the leak is fixed by never adopting a fresh registrar on a content-equal
assignment of a `FeatureState` value.

Source files touched:

- [`Sources/Lattice/Observation/ObservationStateRegistrar.swift`](../Sources/Lattice/Observation/ObservationStateRegistrar.swift) — one new overload.
- [`Sources/Lattice/Observation/FeatureState.swift`](../Sources/Lattice/Observation/FeatureState.swift) — DEBUG-only test hook.
- `Tests/LatticeTests/PresentationTests/ObservableStateAssignmentTests.swift`
- The timer-driven profiling feature `ExampleProject/TimerLeakExamplePackage`.

**No macro changes.** The generated setter call site is unchanged; overload resolution selects
the new overload automatically.

## Design

### Invariant

> Assigning a `@FeatureState` value that is **content-equal** to the current value never
> swaps the current value's `ObservationRegistrar` instance.

A registrar instance is only ever orphaned on a *silent* swap. If the silent branch keeps the
existing value instead of adopting a freshly-constructed one, nothing is orphaned, at any
depth, Equatable or not.

### Mechanism

A single `Value: FeatureState`-constrained overload of `ObservationStateRegistrar.mutate`.
Swift's overload resolution selects it automatically at every macro-generated setter that
stores a `FeatureState` member (the stored type is concrete and conforms), so **no change
to the generated setter is required**. Lattice has no `Perceptible`/`PerceptionRegistrar`
parallel path (unlike TCA upstream), so exactly one overload covers every call site.

The overload mirrors the unconstrained body and changes **only** the silent branch:

- **Identity-equal** (same `_$id`, e.g. copy-mutate-reassign): the registrar context is shared
  between `value` and `newValue`, so `value = newValue` orphans nothing. Apply silently —
  identical to the unconstrained overload, and required so a same-identity content change is
  not dropped.
- **Content-equal but fresh identity** (the leak case): keep the existing value and its
  registrar/`_$id` untouched. Do not adopt `newValue`.
- **Content-changed**: fire one `withMutation` and replace wholesale — identical to the
  unconstrained overload, and leak-safe (SwiftUI re-tracks the new subtree and releases the
  old).

### Why this covers nested `FeatureState` at every depth

Nesting is handled by *not writing*, not by recursion:

- On a content-equal assignment of `parent.child`, the constrained overload returns without
  touching `_child`. Because `_child` is never reassigned, `Child`'s registrar **and** every
  descendant registrar (`Child.leaf`, etc.) are preserved untouched. Leak-free at all depths.
- On a content-changed assignment, `_child = newValue` is a single wholesale struct
  assignment inside `withMutation`. Descendant `_$id`s are re-minted, but the old subtree is
  released (firing branch, leak-safe). Per-field/per-leaf identity preservation on the
  *changed* branch is explicitly **out of scope** (see below).

### Root replacement

The rule covers members; the root state is not a member of anything. The view model applies
the same rule in its commit step: when the interactor replaces the whole state
(`state = State(...)`) and the feature's `areStatesEqual` reports equal content, the stored
value is kept, so its registrar tree and every observer registered on it survive. A
content-changed replacement fires the view model's coarse `\.state` and is leak-safe for the
same reason as the changed branch above. See
[ViewModel Event Loop And Emission Handling](./view-model-event-loop-and-emission-handling.md#commit-rules).

## Runtime changes

### `Sources/Lattice/Observation/ObservationStateRegistrar.swift`

The constrained overload sits directly after the unconstrained `mutate`. The unconstrained
`mutate`, `access`, `willModify`, and `didModify` are unchanged.

```diff
     @inlinable
     public func mutate<Subject: Observable, Member, Value>(
         _ subject: Subject,
         keyPath: KeyPath<Subject, Member>,
         _ value: inout Value,
         _ newValue: Value,
         _ isIdentityEqual: (Value, Value) -> Bool,
         _ shouldNotifyObservers: (Value, Value) -> Bool = { _, _ in true }
     ) {
         if isIdentityEqual(value, newValue) || !shouldNotifyObservers(value, newValue) {
             value = newValue
         } else {
             self.registrar.withMutation(of: subject, keyPath: keyPath) {
                 value = newValue
             }
         }
     }
+
+    /// Mutates a `FeatureState` member, preserving its observation identity when the
+    /// incoming value is content-equal.
+    ///
+    /// Overload resolution prefers this (more-constrained) variant wherever a stored member
+    /// conforms to `FeatureState`. When `newValue` is content-equal to the current value
+    /// but carries a different `_$id` (a freshly constructed value), the current value — and
+    /// its `ObservationRegistrar`/`_$id` at every nested depth — is kept as-is rather than
+    /// replaced, so observers continue tracking the same identity. Identity-equal and
+    /// content-changed assignments behave exactly as the unconstrained `mutate`.
+    @inlinable
+    public func mutate<Subject: Observable, Member, Value: FeatureState>(
+        _ subject: Subject,
+        keyPath: KeyPath<Subject, Member>,
+        _ value: inout Value,
+        _ newValue: Value,
+        _ isIdentityEqual: (Value, Value) -> Bool,
+        _ shouldNotifyObservers: (Value, Value) -> Bool = { _, _ in true }
+    ) {
+        if isIdentityEqual(value, newValue) {
+            // Same identity: the registrar context is shared with `newValue`, so assign
+            // directly.
+            value = newValue
+        } else if !shouldNotifyObservers(value, newValue) {
+            // Content-equal with a different identity: keep the current value so its
+            // registrar/`_$id` — and those of its nested members — are preserved.
+        } else {
+            self.registrar.withMutation(of: subject, keyPath: keyPath) {
+                value = newValue
+            }
+        }
+    }
```

The `_modify`/`willModify`/`didModify` in-place path stays on the unconstrained overload.
`didModify<Subject, Member>` is generic over an unconstrained `Member`, so its internal
`self.mutate(...)` call can only resolve to the unconstrained overload — the new overload is
never reached there. In-place mutation already preserves the registrar instance, so it never
participated in the leak.

### `Sources/Lattice/Observation/FeatureState.swift` (DEBUG test hook)

Exposes the identity of the `ObservableStateID` backing storage so the deterministic regression
test can assert the storage instance is *reused* (not replaced) across many content-equal
assignments.

```diff
 public struct ObservableStateID: Equatable, Hashable, Sendable {
@@
     private var storage: Storage
+
+    #if DEBUG
+    /// Test-only: the identity of the backing storage, so tests can assert that an id's
+    /// storage instance is shared across content-equal assignments.
+    public var _$storageObjectID: ObjectIdentifier { ObjectIdentifier(self.storage) }
+    #endif
```

## Behavior matrix

| Scenario | Before | After |
|---|---|---|
| `FeatureState` child, content-equal wholesale rebuild | silent registrar swap → **leak** | no-op, value + entire subtree identity preserved |
| `FeatureState` child, same `_$id` (copy-mutate-reassign) | silent replace | silent replace (registrar shared, unchanged) |
| `FeatureState` child, content changed | `withMutation` + full replace | `withMutation` + full replace (unchanged; subtree re-minted, leak-safe) |
| Non-`Equatable` child, rebuild | `withMutation` + full replace every tick | `withMutation` + full replace every tick (unchanged; `shouldNotifyObservers` is always `true`) |
| In-place mutation (`x.y = z`) | unchanged | unchanged (uses the unconstrained overload) |
| Non-`FeatureState` member (`Int`, `String`, collection, …) | unchanged | unchanged (uses the unconstrained overload) |

The only behavioral delta was the first row: a content-equal wholesale rebuild of a
`FeatureState` member no longer re-mints identity (and no longer leaks). Every other path is
byte-for-byte the prior behavior.

## Verification

The leak only exists under live SwiftUI `ObservationTracking` — without an observer holding the
old registrar, ARC frees the orphan immediately, so a pure unit test cannot reproduce it.
Verification is a demo-app memory profile, performed as a strict A/B.

### 1. The timer feature: `ExampleProject/TimerLeakExamplePackage`

The feature satisfies the conditions without which the leak does not appear (a false
negative):

1. **Nested `@FeatureState` child** inside the state: `TimerLeakState.child` is a
   `TimerChildState` holding `TimerLeakConstants.rowCount` (500) `@FeatureState` rows.
2. A **timer** (an `AsyncStream` driven from an `.observe` emission) firing about 50 Hz, whose
   interactor **rebuilds the child wholesale every tick**:
   `state.child = TimerChildState(value: state.displayedValue)`.
3. **Content is equal on almost every tick**: the `@Domain` `displayedValue` changes only every
   100 ticks. This forces the content-equal leak path. If content changed every tick, every
   assignment would take the (always-fine) firing branch and nothing would leak in either
   build.
4. **The view reads a leaf of the child on every render**: a `TimelineView` re-renders the rows
   continuously, and each row view reads `row.value`, so SwiftUI tracks every row registrar.

### 2. Profile without the fix to confirm the leak exists

With the feature on screen, run for 60–120 s and watch persistent memory:

- Instruments → **Allocations**, filter persistent allocations of the Observation registrar
  context type; or
- the simplest A/B signal: the demo's `ResidentMemoryOverlay`, which samples
  `mach_task_basic_info().resident_size` once per second on screen.

Expected: **linear growth** (~the measured 44 MB/hr). Do not proceed until the baseline leak is
reproduced — without it, a later "flat" reading proves nothing.

### 3. Apply the fix

The constrained `mutate` overload (and the DEBUG hook). Runtime-only; no macro change.

### 4. Profile again to confirm the fix

Run the identical feature for the identical duration. Expected: **flat** persistent memory.

Because the content-equal path is the entire leak, a flat result here is conclusive: there is
no additional fix (including the per-field merge alternative in *Out of scope*) that would
reduce the leak further.

### Deterministic regression gate (CI)

Not a leak repro (no SwiftUI), but a fast invariant check that locks the behavior so the leak
cannot silently return.
`Tests/LatticeTests/PresentationTests/ObservableStateAssignmentTests.swift`:

```swift
import Observation
import Testing

@testable import Lattice

@FeatureState private struct Leaf: Equatable { var n: Int }
@FeatureState private struct Child: Equatable { var value: String; var leaf: Leaf }
@FeatureState private struct Parent: Equatable { var title: String; var child: Child }

@Suite struct ObservableStateAssignmentTests {
    @Test func contentEqualRebuildPreservesNestedIdentity() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        let pid = a._$id, cid = a.child._$id, lid = a.child.leaf._$id

        a.child = Child(value: "x", leaf: Leaf(n: 1))  // content-equal wholesale rebuild

        #expect(a._$id == pid)
        #expect(a.child._$id == cid)
        #expect(a.child.leaf._$id == lid)
    }

    #if DEBUG
        @Test func contentEqualRebuildReusesStorageAcrossManyTicks() {
            var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
            let storage = a.child._$id._$storageObjectID

            for _ in 0..<1_000 {
                a.child = Child(value: "x", leaf: Leaf(n: 1))  // simulate rebuild churn
            }

            #expect(a.child._$id._$storageObjectID == storage)  // one instance, not 1000
        }
    #endif

    @Test func contentChangeStillApplies() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        a.child = Child(value: "x", leaf: Leaf(n: 2))
        #expect(a.child == Child(value: "x", leaf: Leaf(n: 2)))
    }

    @Test func contentEqualRebuildDoesNotNotify() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        nonisolated(unsafe) var fired = false
        withObservationTracking { _ = a.child.leaf.n } onChange: { fired = true }
        a.child = Child(value: "x", leaf: Leaf(n: 1))
        #expect(!fired)
    }

    @Test func contentChangeNotifies() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        nonisolated(unsafe) var fired = false
        withObservationTracking { _ = a.child.leaf.n } onChange: { fired = true }
        a.child = Child(value: "x", leaf: Leaf(n: 2))
        #expect(fired)
    }

    // A `ViewState` is a copy that shares the state's registrars, so reads through it are
    // notified exactly like reads on the state.
    @Test func projectionReadsShareTheStateRegistrars() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        let viewState = Parent.ViewState(a)
        nonisolated(unsafe) var fired = false
        withObservationTracking { _ = viewState.child.leaf.n } onChange: { fired = true }

        a.child = Child(value: "x", leaf: Leaf(n: 1))  // content-equal rebuild
        #expect(!fired)

        a.child.leaf.n = 2
        #expect(fired)
    }
}
```

`ViewModelObservationTests` runs the same rows through a `ViewModel`
(`contentEqualChildRebuildIsSilentAndPreservesTheChildID`,
`childRebuiltWithDifferentContentFiresObserversThroughTheChild`), plus the root rows
(`wholesaleReplacementWithEqualContentIsSilentAndPreservesRegistrars`,
`wholesaleReplacementWithEqualContentFiresRootWithoutStateEquality`).

## Migration / breaking-change notes

- **Source-compatible**: no protocol, macro, or generated-output change. Consumers rebuild and
  pick up the fix with no code changes.
- **Behavioral change** (one path only): assigning a content-equal `@FeatureState` member no
  longer re-mints its `_$id`. Code that (incorrectly) relied on a fresh `_$id` per assignment
  changes behavior. No such reliance exists in the test suite (`_$id` is never asserted to
  change on assignment).

## Out of scope (deliberate)

- **Per-field merge / `_$merge`.** A recursive, macro-synthesized merge would additionally
  preserve identity and notify per-changed-leaf on *content-changed* rebuilds (animation/focus
  stability, fewer invalidations). That is an optimization, **not** the leak — the changed
  branch is already leak-safe. It carries a protocol requirement, struct/enum/`let` codegen, and
  rewrites of every macro-expansion snapshot test. Add it only if a profile shows the coarse
  content-changed notification or lost subtree identity actually costs something.
- **Element-wise handling for `Array`/`IdentifiedArray` of `FeatureState`.** Collections use
  the unconstrained `mutate`: a content-equal collection rebuild is short-circuited at an
  `Equatable` parent before reaching the elements, and a content-changed collection fires a
  mutation (SwiftUI cleans up). Add element-wise diffing only if list churn shows up in a
  profile.

## Validation checklist

1. `swift build`
2. `swift test --filter ObservableStateAssignmentTests` — invariants + notification + no-churn.
3. `swift test` — full suite; confirm `ViewModelObservationTests` still passes (notifications
   not regressed).
4. Demo-app profile A/B (steps 1–4 under *Verification*): leak reproduced without the fix, flat
   with it.
5. Spot-check that `ExampleProject/` builds.

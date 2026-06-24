# Identity-Preserving Assignment for `@ObservableState`

Status: ✅ Implemented (minimal, source- and behavior-compatible)

## Problem

Every `@ObservableState` value carries a macro-synthesized, `@ObservationStateIgnored`
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
}
```

So *mutating* a value carries identity forward, but *constructing* one mints new identity.
A `ViewStateReducer` (or any reducer) that rebuilds a nested `@ObservableState` value
wholesale instead of mutating it —

```swift
BuildViewState { domain, viewState in
    viewState.child = ChildViewState(/* recomputed every tick */)   // wholesale rebuild
}
```

— hits the silent branch of `ObservationStateRegistrar.mutate`:

```swift
// current
if isIdentityEqual(value, newValue) || !shouldNotifyObservers(value, newValue) {
    value = newValue          // <-- content-equal Equatable rebuild: adopts a FRESH registrar
} else {                      //     instance with NO withMutation -> SwiftUI never re-accesses
    self.registrar.withMutation(of: subject, keyPath: keyPath) { value = newValue }
}
```

For a content-equal `Equatable` child: `isIdentityEqual == false` (fresh `_$id`),
`shouldNotifyObservers == false` (equal). The first branch silently installs a new
`ObservationRegistrar` instance. SwiftUI's active `ObservationTracking` still retains the
*previous* registrar context (to call `cancel` later) but no mutation ever fires for that
subtree, so it is never reused or released. New contexts accumulate — the measured
~18 registrars/s ≈ 44 MB/hr.

Wholesale rebuild is the *idiomatic* way to derive view state from domain state, so this is
not consumer misuse — it is a silent, unbounded production leak triggered by reasonable code.

## Scope of the leak

The leak is **entirely** the content-equal silent registrar swap (the first branch above).
The content-*changed* branch already fires `withMutation`, so SwiftUI re-accesses the subtree,
re-establishes tracking on the new registrars, and releases the old ones. That branch never
leaked. Therefore the leak is fixed by never adopting a fresh registrar on a content-equal
assignment of an `ObservableState` value.

Source files touched:

- [`Sources/Lattice/Observation/ObservationStateRegistrar.swift`](../Sources/Lattice/Observation/ObservationStateRegistrar.swift) — one new overload.
- [`Sources/Lattice/Observation/ObservableState.swift`](../Sources/Lattice/Observation/ObservableState.swift) — DEBUG-only test hook.
- New: `Tests/LatticeTests/PresentationTests/ObservableStateAssignmentTests.swift`
- New (throwaway, for profiling): a timer-driven feature in `ExampleProject/`.

**No macro changes.** `Sources/LatticeMacros/*`, `Sources/Lattice/Macros.swift`, and the
checked-in macro binary are untouched. The generated setter call site is unchanged; overload
resolution selects the new overload automatically. `scripts/rebuild-macro.sh` is **not**
required.

## Design

### Invariant

> Assigning an `@ObservableState` value that is **content-equal** to the current value never
> swaps the current value's `ObservationRegistrar` instance.

A registrar instance is only ever orphaned on a *silent* swap. If the silent branch keeps the
existing value instead of adopting a freshly-constructed one, nothing is orphaned, at any
depth, Equatable or not.

### Mechanism

Add a single `Value: ObservableState`-constrained overload of `ObservationStateRegistrar.mutate`.
Swift's overload resolution selects it automatically at every macro-generated setter that
stores an `ObservableState` member (the stored type is concrete and conforms), so **no change
to the generated setter is required**. Lattice has no `Perceptible`/`PerceptionRegistrar`
parallel path (unlike TCA upstream), so exactly one overload covers every call site.

The overload mirrors the existing unconstrained body and changes **only** the silent branch:

- **Identity-equal** (same `_$id`, e.g. copy-mutate-reassign): the registrar context is shared
  between `value` and `newValue`, so `value = newValue` orphans nothing. Apply silently —
  identical to the unconstrained overload, and required so a same-identity content change is
  not dropped.
- **Content-equal but fresh identity** (the leak case): keep the existing value and its
  registrar/`_$id` untouched. Do not adopt `newValue`.
- **Content-changed**: fire one `withMutation` and replace wholesale — identical to the
  unconstrained overload, and leak-safe (SwiftUI re-tracks the new subtree and releases the
  old).

### Why this covers nested `ObservableState` at every depth

Nesting is handled by *not writing*, not by recursion:

- On a content-equal assignment of `parent.child`, the constrained overload returns without
  touching `_child`. Because `_child` is never reassigned, `Child`'s registrar **and** every
  descendant registrar (`Child.leaf`, etc.) are preserved untouched. Leak-free at all depths.
- On a content-changed assignment, `_child = newValue` is a single wholesale struct
  assignment inside `withMutation`. Descendant `_$id`s are re-minted, but the old subtree is
  released (firing branch, leak-safe). Per-field/per-leaf identity preservation on the
  *changed* branch is explicitly **out of scope** (see below).

## Runtime changes

### `Sources/Lattice/Observation/ObservationStateRegistrar.swift`

Add the constrained overload directly after the existing unconstrained `mutate`. The existing
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
+    /// Mutates an `ObservableState` member, preserving its observation identity when the
+    /// incoming value is content-equal.
+    ///
+    /// Overload resolution prefers this (more-constrained) variant wherever a stored member
+    /// conforms to `ObservableState`. When `newValue` is content-equal to the current value
+    /// but carries a different `_$id` (a freshly constructed value), the current value — and
+    /// its `ObservationRegistrar`/`_$id` at every nested depth — is kept as-is rather than
+    /// replaced, so observers continue tracking the same identity. Identity-equal and
+    /// content-changed assignments behave exactly as the unconstrained `mutate`.
+    @inlinable
+    public func mutate<Subject: Observable, Member, Value: ObservableState>(
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

### `Sources/Lattice/Observation/ObservableState.swift` (DEBUG test hook)

Expose the identity of the `ObservableStateID` backing storage so the deterministic regression
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
| `ObservableState` child, content-equal wholesale rebuild | silent registrar swap → **leak** | no-op, value + entire subtree identity preserved |
| `ObservableState` child, same `_$id` (copy-mutate-reassign) | silent replace | silent replace (registrar shared, unchanged) |
| `ObservableState` child, content changed | `withMutation` + full replace | `withMutation` + full replace (unchanged; subtree re-minted, leak-safe) |
| Non-`Equatable` child, rebuild | `withMutation` + full replace every tick | `withMutation` + full replace every tick (unchanged; `shouldNotifyObservers` is always `true`) |
| In-place mutation (`x.y = z`) | unchanged | unchanged (uses the unconstrained overload) |
| Non-`ObservableState` member (`Int`, `String`, collection, …) | unchanged | unchanged (uses the unconstrained overload) |

The only behavioral delta versus today is the first row: a content-equal wholesale rebuild of
an `ObservableState` member no longer re-mints identity (and no longer leaks). Every other path
is byte-for-byte the prior behavior.

## Verification

The leak only exists under live SwiftUI `ObservationTracking` — without an observer holding the
old registrar, ARC frees the orphan immediately, so a pure unit test cannot reproduce it.
Verification is a demo-app memory profile, performed as a strict A/B in this order:

### 1. Build a throwaway timer feature in `ExampleProject/`

The feature must satisfy three conditions, or the leak will not appear and the result is a
false negative:

1. **Nested `@ObservableState` child** inside the view state.
2. A **timer** (`Timer.publish`, or an `AsyncStream` driven from an `.observe` emission) firing
   ~30–60 Hz, whose reducer **rebuilds the child wholesale every tick**:
   `viewState.child = ChildViewState(...)`.
3. **Content is equal on almost every tick** — change a leaf value only rarely (e.g. every
   ~100 ticks) or never. This forces the content-equal leak path. If content changes every
   tick, every assignment takes the (always-fine) firing branch and nothing leaks in either
   build.
4. The **view must read a leaf field of the child on every render** (e.g. `Text(child.value)`),
   or SwiftUI never tracks the child's registrar and there is nothing to orphan.

### 2. Profile on current `main` to confirm the leak exists

With the feature on screen, run for 60–120 s and watch persistent memory:

- Instruments → **Allocations**, filter persistent allocations of the Observation registrar
  context type; or
- the simplest A/B signal: sample resident size in-app once per second
  (`mach_task_basic_info().resident_size`) and print it to an on-screen overlay.

Expected: **linear growth** (~the measured 44 MB/hr). Do not proceed until the baseline leak is
reproduced — without it, a later "flat" reading proves nothing.

### 3. Apply the fix

Add the constrained `mutate` overload (and the DEBUG hook). Runtime-only; no macro rebuild.

### 4. Profile again to confirm the fix

Run the identical feature for the identical duration. Expected: **flat** persistent memory.

Because the content-equal path is the entire leak, a flat result here is conclusive: there is
no additional fix (including the per-field merge alternative in *Out of scope*) that would
reduce the leak further.

### Deterministic regression gate (CI)

Not a leak repro (no SwiftUI), but a fast invariant check that locks the behavior so the leak
cannot silently return. New file
`Tests/LatticeTests/PresentationTests/ObservableStateAssignmentTests.swift`:

```swift
import Observation
import Testing

@testable import Lattice

@ObservableState private struct Leaf: Equatable { var n: Int }
@ObservableState private struct Child: Equatable { var value: String; var leaf: Leaf }
@ObservableState private struct Parent: Equatable { var title: String; var child: Child }

@Suite struct ObservableStateAssignmentTests {
    @Test func contentEqualRebuildPreservesNestedIdentity() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        let pid = a._$id, cid = a.child._$id, lid = a.child.leaf._$id

        a.child = Child(value: "x", leaf: Leaf(n: 1))   // content-equal wholesale rebuild

        #expect(a._$id == pid)
        #expect(a.child._$id == cid)
        #expect(a.child.leaf._$id == lid)
    }

    #if DEBUG
    @Test func contentEqualRebuildReusesStorageAcrossManyTicks() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        let storage = a.child._$id._$storageObjectID

        for _ in 0..<1_000 {
            a.child = Child(value: "x", leaf: Leaf(n: 1))   // simulate reducer churn
        }

        #expect(a.child._$id._$storageObjectID == storage)   // one instance, not 1000
    }
    #endif

    @Test func contentChangeStillApplies() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        a.child = Child(value: "x", leaf: Leaf(n: 2))
        #expect(a.child == Child(value: "x", leaf: Leaf(n: 2)))
    }

    @Test func contentEqualRebuildDoesNotNotify() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        var fired = false
        withObservationTracking { _ = a.child.leaf.n } onChange: { fired = true }
        a.child = Child(value: "x", leaf: Leaf(n: 1))
        #expect(!fired)
    }

    @Test func contentChangeNotifies() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        var fired = false
        withObservationTracking { _ = a.child.leaf.n } onChange: { fired = true }
        a.child = Child(value: "x", leaf: Leaf(n: 2))
        #expect(fired)
    }
}
```

## Migration / breaking-change notes

- **Source-compatible**: no protocol, macro, or generated-output change. Consumers rebuild and
  pick up the fix with no code changes.
- **Behavioral change** (one path only): assigning a content-equal `@ObservableState` member no
  longer re-mints its `_$id`. Code that (incorrectly) relied on a fresh `_$id` per assignment
  changes behavior. No such reliance exists in the current test suite (`_$id` is never asserted
  to change on assignment).

## Out of scope (deliberate)

- **Per-field merge / `_$merge`.** A recursive, macro-synthesized merge would additionally
  preserve identity and notify per-changed-leaf on *content-changed* rebuilds (animation/focus
  stability, fewer invalidations). That is an optimization, **not** the leak — the changed
  branch is already leak-safe. It carries a protocol requirement, struct/enum/`let` codegen, a
  macro binary rebuild, and rewrites of every macro-expansion snapshot test. Add it only if a
  profile shows the coarse content-changed notification or lost subtree identity actually costs
  something.
- **Element-wise handling for `Array`/`IdentifiedArray` of `ObservableState`.** Collections use
  the unconstrained `mutate`: a content-equal collection rebuild is short-circuited at an
  `Equatable` parent before reaching the elements, and a content-changed collection fires a
  mutation (SwiftUI cleans up). Add element-wise diffing only if list churn shows up in a
  profile.

## Validation checklist

1. `swift build`
2. `swift test --filter ObservableStateAssignmentTests` — invariants + notification + no-churn.
3. `swift test` — full suite; confirm `ViewModelObservationTests` and `ViewStateReducerTests`
   still pass (notifications not regressed).
4. Demo-app profile A/B (steps 1–4 under *Verification*): leak reproduced on `main`, flat after
   the fix.
5. Spot-check `ExampleProject/` builds. No macro binary rebuild required.

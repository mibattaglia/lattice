# 08 — Macros: Surviving `@Interactor`, Deleted Observation/Reducer Macros, New `@FeatureState` Plugin Work

Workstream 8 of the Sendable-removal rework. Depends on plans `01-toolchain.md` (swift-syntax
pin 601 → 602, macro-binary policy), `04-interactor-combinators.md` (the `Interactor` protocol
and `InteractorBuilder` shapes the surviving macro's generated code must keep compiling
against), and `05-feature-state.md` (the design owner for the new `@FeatureState`/`@Domain`
macros; its §10 deletion table drives this plan's deletions). Runs in parallel with
`09-docs-release.md`.

## Overview

This is **no longer a near-zero audit**. The plugin target has real work in three buckets:

- **(a) Survives:** `@Interactor`. The audit result stands — it emits nothing that touches
  deleted or re-signatured API, so it ships unmodified.
- **(b) Deleted:** the `@ObservableState` family and the `@ViewStateReducer` validation macro,
  their plugin sources, their library-target declarations, and their two test suites
  (14 + 6 tests). Plan 05 §10 replaces both layers with diff-at-commit.
- **(c) New:** `@FeatureState` (member + extension, structs and enums) and the `@Domain`
  marker. Plan 05 owns the design (§§2, 4, 8, 11.3); this plan owns where the code lands in
  the plugin target, the expansion-test strategy, and confirms the macro-binary policy is
  unchanged.

The macro binary remains **consumer-generated, never checked in** — plugin-source churn from
(b) and (c) requires zero maintainer binary work.

## (a) Surviving macro: `@Interactor`

Verified against `Sources/LatticeMacros/Plugins/InteractorMacro.swift`. The macro emits exactly
three artifacts, all of which remain valid under the reworked protocol:

1. **`extension X: Lattice.Interactor {}`** (`InteractorMacro.swift:29–34`, extension role).
   The protocol drops `Sendable` on `DomainState`/`Action` and re-signatures `interact` to
   `(inout DomainState, Action, Effects<DomainState, Action>) -> Void` (plan 04 §1). The
   emitted extension is *empty* — conformance is satisfied by the user's `body` plus the
   protocol's default `interact` forwarding (plan 04 keeps `Body`/`body`). Loosening generic
   constraints and changing a defaulted requirement's signature don't affect an empty
   extension.
2. **`typealias DomainState` / `typealias Action`** (`InteractorMacro.swift`, member role;
   emitted from the attribute's two generic arguments). Pure names; the types no longer need
   `Sendable`, which only *widens* what users may write.
3. **`@Lattice.InteractorBuilder<DomainState, Action>` member attribute on `body`**
   (`InteractorMacro.swift:73–74`, member-attribute role). Plan 04 §9 re-declares
   `public enum InteractorBuilder<State, Action>` — same name, same arity, constraints
   dropped. The emitted attribute syntax is byte-identical.

`grep -rn 'Sendable\|Emission' Sources/LatticeMacros/` → **no matches** anywhere in the plugin
target, so no plugin source references a deleted symbol. The `Extensions/` syntax helpers
(`Availability.swift`, `Extensions.swift`, `String+Extensions.swift`) are macro-agnostic and
stay; `@FeatureState` will reuse them.

`InteractorMacroTests` (5 tests, `MacroTesting.assertMacro` syntax-only expansion) survives
unmodified. Fixture bodies referencing old-world expressions (e.g.
`InteractorMacroTests.swift:23` uses `EmptyInteractor()`) are inert strings to the expander;
cosmetic modernization buys nothing and is skipped.

## (b) Deleted macros: `@ObservableState` family and `@ViewStateReducer`

Plan 05 §10 deletes the ViewStateReducer layer and the copy-identity observation machinery.
The macro-side execution, all in this workstream (sequenced with plan 05 phase C, when plan 6
flips the ViewModel):

**Plugin sources deleted:**

| File | Contents |
|---|---|
| `Sources/LatticeMacros/Plugins/Derived/ObservableStateMacro.swift` | `ObservableStateMacro`, `ObservationStateTrackedMacro`, `ObservationStateIgnoredMacro` (all three live in this one file; the `Derived/` directory goes with it) |
| `Sources/LatticeMacros/Plugins/ViewStateReducerMacro.swift` | `ViewStateReducerMacro` incl. the `initialViewState(for:)` / `DefaultValueProvider` validation — deleted with nothing to validate: there is no second state type to seed |

**Registration:** `Plugins/Plugin.swift` drops `ViewStateReducerMacro.self`,
`ObservableStateMacro.self`, `ObservationStateIgnoredMacro.self`,
`ObservationStateTrackedMacro.self` from `providingMacros` (and gains the two new macros,
see (c)).

**Library-target declarations:** `Sources/Lattice/Macros.swift` deletes the
`@ViewStateReducer`, `@ObservableState`, `@ObservationStateTracked`, and
`@ObservationStateIgnored` macro declarations and the `import Observation` they required.
Only the `@Interactor` declaration remains in that file (doc-comment update below). The
runtime symbols the deleted macros emitted (`ObservationStateRegistrar`, `ObservableStateID`,
`_$id`, `_$willModify`, `DefaultValueProvider`, `Sources/Lattice/Observation/**`) are on plan
05 §10's deletion table — the previous revision of this plan pinned the Observation layer as
"survives untouched"; that is now false and superseded.

**Test suites deleted:**

| Suite | Tests | Why |
|---|---|---|
| `Tests/LatticeMacrosTests/ObservableStateMacroTests.swift` | 14 | asserts expansions of a deleted macro |
| `Tests/LatticeMacrosTests/ViewStateReducerMacroTests.swift` | 6 | asserts expansions of a deleted macro |

Baseline on the current tree: `swift test --filter LatticeMacrosTests` — **25 tests, 0
failures** (`InteractorMacroTests` 5, `ViewStateReducerMacroTests` 6,
`ObservableStateMacroTests` 14). After this workstream the suite is `InteractorMacroTests`
(5, unmodified) plus the new `FeatureStateMacroTests` (see (c)).

## (c) New macro work: `@FeatureState` / `@Domain`

**Plan 05 is the design owner — do not re-derive the design here.** In one paragraph:
`@FeatureState` attaches to structs and enums and generates four members — the `_ViewMembers`
key-path namespace over view-visible members (compile-time `@Domain`/private fencing), the
`_viewKeyPaths` map, the `_derivedMembers` set naming the computed (derived) members, and the
`_commit(old:new:registrar:key:)` diff that fires the host-owned
registrar only for members whose value/output changed (stored members via `_diff`, computed
members via `commitDerived`) — plus enum case accessors and a
`FeatureStateProtocol` conformance extension; `@Domain` is an empty peer marker. Diagnostics
(the type-driven non-`Equatable` visible-member error via the unavailable `_diff` overload,
the syntactic collection-returning-computed warning, the cycle warning, and the rest of the
table) are specified in plan 05 §8; hand expansions that are the normative test baselines are
plan 05 §4; the macro-workstream summary is plan 05 §11.3.

What **this** plan owns — the plugin-target mechanics:

- **Where the code lands:**
  - `Sources/LatticeMacros/Plugins/FeatureStateMacro.swift` — member + extension macro
    (visibility + stored/computed classification,
    `_ViewMembers`/`_viewKeyPaths`/`_derivedMembers`/`_commit` emission for structs;
    case-accessor + case-switch emission for enums; plan 05 §8's syntactic diagnostics).
    Substantially simpler than the `ObservableStateMacro` it replaces: no accessor rewriting,
    no `_$id` threading, no `willSet` synthesis — output is four declarative members.
  - `Sources/LatticeMacros/Plugins/DomainMacro.swift` — empty peer expansion (the same no-op
    pattern as today's `ObservationStateIgnoredMacro`).
  - Registration in `Plugins/Plugin.swift` alongside `InteractorMacro`.
  - Library-target `#externalMacro` declarations in
    `Sources/Lattice/FeatureState/FeatureStateMacros.swift` (plan 05 §2.1 pins the
    attachment kinds and names), *not* in `Sources/Lattice/Macros.swift` — the new state
    layer keeps its declarations next to its runtime types. (Named `FeatureStateMacros.swift`
    rather than `Macros.swift`: SwiftPM cannot build two same-named files in one target.)
  - Reuse the existing `Extensions/` syntax helpers (`moduleQualified`, availability copying)
    rather than duplicating them.
- **Expansion-test strategy:** `Tests/LatticeMacrosTests/FeatureStateMacroTests.swift` using
  the already-present harness — **swift-macro-testing is already a dependency**
  (`Package.swift:33` pin, `:85` `MacroTesting` product on the test target); no manifest
  change. One `assertMacro` test per plan 05 §4 hand expansion (representative struct, enum,
  collection-bearing parent) with the §4 text as the exact-match checked-in baseline, plus one
  test per diagnostic row in plan 05 §8's table. Any expansion change is a reviewed baseline
  diff. Type-driven checks (the unavailable `_diff` overload) cannot be exercised by
  syntax-only expansion tests — they are covered by plan 05 phase A's compile-fail fixtures in
  the runtime test target, not here.
- **Macro-binary policy: unchanged** (plan 01). `Macros/LatticeMacros` is never checked in.
  SwiftPM/Xcode consumers build the `.macro` target from source; CocoaPods consumers generate
  the binary at `pod install` via `prepare_command` → `scripts/rebuild-macro.sh`
  (`Lattice.podspec` `preserve_paths` / `-load-plugin-executable` point at the consumer-side
  artifact). Adding/deleting plugin sources requires **no maintainer binary action** —
  consumers always build from current sources, and the swift-syntax 601 → 602 bump reaches pod
  consumers automatically at their next `pod install`. `SKIP_LATTICE_MACRO_BUILD=1` remains
  the consumer escape hatch.

Sequencing: `FeatureStateMacro`/`DomainMacro` land in plan 05 phase B (after the phase-A
runtime spike proves the hand expansions compile and behave); the deletions in (b) execute in
phase C with plans 6/7. Between B and C the plugin carries old and new macros side by side —
that is fine, they share no symbols.

## Change plan for `Sources/Lattice/Macros.swift`

Two edits to this file across the rework, both owned here so workstream 9 never touches macro
declarations:

1. **Doc comment on `@Interactor`** (after plan 04 merges, so the example matches shipped
   API): the example shows `Interact(initialValue:)`, `return .state`, and a `: Sendable`
   annotation (`Macros.swift:9,11,13`); align with plan 04's post-rework `Interact`
   (trailing-closure init, `Void` return, no `Sendable`):

```diff
 /// ```swift
 /// @Interactor<CounterState, CounterAction>
-/// struct CounterInteractor: Sendable {
+/// struct CounterInteractor {
 ///     var body: some InteractorOf<Self> {
-///         Interact(initialValue: CounterState()) { state, action in
-///             // Handle actions
-///             return .state
+///         Interact { state, action in
+///             // Handle actions by mutating state
 ///         }
 ///     }
 /// }
 /// ```
```

2. **Deletion of the `@ViewStateReducer` / `@ObservableState` / `@ObservationStateTracked` /
   `@ObservationStateIgnored` declarations** and `import Observation` (phase C, with (b)'s
   plugin deletions — declarations and plugin implementations must go in the same change or
   `#externalMacro` resolution breaks the build).

The `@Interactor` declaration's *signature* (attached kinds, introduced names, generic arity)
does not change — it maps 1:1 onto the surviving protocol shape.

## Rebuild & verification commands

```bash
# 1. No deleted-symbol references in plugin or macro tests (run after each phase):
grep -rn 'Sendable\|Emission' Sources/LatticeMacros/ Tests/LatticeMacrosTests/  # expect: no matches

# 2. After phase C: no trace of the deleted macros anywhere in the plugin or its tests:
grep -rn 'ViewStateReducer\|ObservableState\|ObservationState' Sources/LatticeMacros/ Tests/LatticeMacrosTests/  # expect: no matches

# 3. Macro suite green at each phase boundary:
swift test --filter LatticeMacrosTests
#   pre-rework baseline: 25/25 (Interactor 5, ViewStateReducer 6, ObservableState 14)
#   after phase B:       25 + FeatureStateMacroTests (new expansions + diagnostics)
#   after phase C:       InteractorMacroTests 5 + FeatureStateMacroTests only

# 4. Pod prepare_command path still works on the 6.2 manifest with the new plugin sources
#    (verify-and-discard):
scripts/rebuild-macro.sh
lipo -info Macros/LatticeMacros            # sanity: valid Mach-O
rm -rf Macros/                             # consumer-side artifact; never committed (gitignored by plan 01)

# 5. Generated-code compatibility end-to-end: @Interactor and @FeatureState consumers in the
#    library tests compiling and passing under the new protocol shapes proves the emitted
#    syntax is valid against the real runtime:
swift build && swift test --filter LatticeTests
swift test --filter FeatureStateRuntimeTests   # plan 05 gate: real expansion, same behavior
```

## Acceptance gates

1. `InteractorMacroTests` passes with the same 5 tests, **zero test-file edits** relative to
   the pre-rework tree.
2. `Tests/LatticeMacrosTests/FeatureStateMacroTests.swift` exists with one exact-match
   expansion baseline per plan 05 §4 example and one test per implemented plan 05 §8
   syntactic-diagnostic row, all green. (The `@FeatureState`-returning computed-member
   warning row is not implementable with the attached-macro API — macros cannot resolve
   sibling types — and is deferred; plan 05 §8 marks it accordingly.)
3. After phase C, `Sources/LatticeMacros/` contains exactly: `Plugins/Plugin.swift`,
   `Plugins/InteractorMacro.swift`, `Plugins/FeatureStateMacro.swift`,
   `Plugins/DomainMacro.swift`, and `Extensions/**`. `Plugins/Derived/` and
   `ViewStateReducerMacro.swift` are gone; grep gate 2 above is clean.
4. `ObservableStateMacroTests.swift` and `ViewStateReducerMacroTests.swift` are deleted, not
   skipped or fixture-stubbed.
5. `Sources/Lattice/Macros.swift` declares only `@Interactor`; the `@FeatureState`/`@Domain`
   declarations live in `Sources/Lattice/FeatureState/FeatureStateMacros.swift` with the
   plan 05 §2.1 attachment kinds.
6. No commit in the release adds `Macros/LatticeMacros` or any binary artifact; `Macros/` is
   gitignored (plan 01) and `scripts/rebuild-macro.sh` succeeds on the final manifest
   (command 4 above, verify-and-discard).
7. Post-integration, an `@Interactor`-annotated feature and a `@FeatureState`-annotated state
   in `Tests/LatticeTests` (or `ExampleProject`, workstream 9) compile without hand-written
   typealiases, conformances, or projection members — proving both macros' emitted syntax
   matches the shipped runtime.

## Risks

- **Enum expansion complexity concentrates here.** Case accessors, single-payload limits,
  name-collision errors, and the case-identity switch are the bulk of `FeatureStateMacro`'s
  branching (plan 05 §13 row 1). Mitigated by exact-match baselines from plan 05 §4.2 and by
  phase A proving the hand expansion before the macro exists.
- **Baseline drift between plan 05 §4 and the checked-in expansions.** The §4 text is
  normative; if implementation forces a divergence (e.g. formatting, availability attributes),
  update plan 05 first, then the baselines — never let the test baselines silently become the
  spec.
- **Stale doc example ships if plan 04's `Interact` surface shifts late** (e.g. handler label
  changes). Low; mitigated by sequencing the `Macros.swift` doc edit after 04 merges and by
  gate 7.
- **Phase C ordering**: deleting plugin implementations while `#externalMacro` declarations
  or `@ObservableState`/`@ViewStateReducer` use sites still exist breaks the build. The
  declarations, plugin sources, runtime Observation layer, and all annotation sites must go
  in one coordinated change (plan 05 phase C with plans 6/7).
- **Hidden macro consumers of deleted API**: none found by exhaustive grep, but if a later
  workstream adds macro-emitted references to new runtime symbols beyond plan 05's set (e.g.
  an `Effects`-aware convenience), that is new plugin work — escalate rather than fold it in
  here silently.

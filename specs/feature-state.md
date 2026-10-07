# Feature State — Standalone Machinery (PR 1)

## Status

`@FeatureState` / `@Domain` and the descriptor-based projection/diff/Observation machinery are additive. Existing `Feature<Action, DomainState, ViewState>`, `ViewModel`, reducers, ObservableState macros, examples, and the Emission/testing runtime remain active and unchanged. Production host integration and reducer removal belong to a separate, breaking PR 2; they are not implemented here.

Projection construction and registrar commit batching are internal host seams, exercised by real-macro test hosts. This PR does not add a competing public host or a raw-state compatibility accessor.

## State and visibility

```swift
@FeatureState
struct SearchDomainState: Equatable, Sendable {
    @Domain var results: [String] = []
    var countText: String { "\(results.count) results" }
}
```

State is an ordinary struct or enum. `FeatureStateProtocol` has no Sendable, Equatable, or Observable inheritance. Existing production domain-state Sendable requirements still apply to every stored input, including `@Domain` data. The macro generates no Sendable conformance and does not isolate state to an actor.

Instance stored properties (including ordinary willSet/didSet observers) and synchronous, nonmutating, get-only computed properties in the annotated declaration are visible unless `@Domain`, private, or fileprivate. Static members and methods do not participate. Visible declarations need explicit type annotations. Properties added in other extensions cannot be discovered by an attached macro.

Generated getters retain their declared access: a public state does not promote an internal getter, package getters retain their boundary, and `public private(set)` remains readable publicly. `@Domain` only filters presentation; it does not restrict ordinary Swift access to raw domain state.

`_ViewMembers` fields are typed descriptors, not raw state values. The ordinary nonisolated factory selects a leaf, feature child, optional child, or identified feature collection once at declaration time. Only reading `_viewMembers` and committing are MainActor-isolated. Generic Equatable equality is captured in a typed closure in that ordinary context, avoiding a conformance transfer into MainActor metadata. Reads and generated commits use the same category. There is no erased namespace key-path map or raw Equatable-child fallback.

Explicit paths identify one namespace member. Descendants use projection chaining (`projection.child.title`), not composed raw-child namespace paths. Descriptor state key paths are internal. Hidden reads and raw child coercions fail at compile time.

### Leaf boundary

Unannotated Equatable leaves are intentionally exposed as whole values. This is not recursive object-graph access control: annotate a wrapper as feature state or mark it `@Domain` when its internals need filtering. Primitive arrays/dictionaries/sets remain whole Equatable leaves.

Stored child and optional child feature states need not be Equatable. Computed outputs must be Equatable. Identified feature rows require FeatureStateProtocol, Identifiable, and Equatable. Ordinary arrays, sets, and dictionaries directly containing feature states (including optional containers/elements and dictionary keys) are rejected, as are optional identified feature containers; use supported identified feature storage or `@Domain`. Type aliases do not bypass the supported-container fence. Arbitrary wrapper reflection is not supported.

Single-payload enum cases get optional visible accessors; fresh inactive lookups return nil. Multiple payloads require one payload struct. Visible conditional member groups, member-specific availability, lazy/effectful/mutating/settable getters, unsupported property attributes/wrappers, and generated-name/case-accessor collisions diagnose. Type-level availability, generic/nested declarations, Self/nested type spellings, and escaped identifiers are supported. Cycle and coarse collection warnings are advisory, best-effort syntax checks.

## Derivation and observation

A host publishes its committed domain snapshot, then batches `_commit(old:new:registrar:key:)`. The registrar owns signals and derived caches, not state identity.

- Stored feature children recurse without whole-child equality shortcuts. Optional/enum presence changes invalidate their subtree.
- Stored identified rows use identity for structure and row equality to skip unchanged rows. Row equality must cover **every input affecting presentation**, including hidden inputs of derived output. It is not Feature's test comparator.
- Computed child, optional-child, and identified-row outputs are coarse cached subtrees. Traversal seeds/registers the parent output; output inequality invalidates descendants and publishes the new parent. Primitive derived collections are ordinary coarse leaves.
- Never-accessed derived members are skipped at commit. Once accessed, a slot is maintained until structural pruning or host teardown, even after Observation's one-shot tracking expires. This is not active-observer or on-screen accounting.
- Each needed generated derived commit entry evaluates its getter once. A getter calling another raw getter uses ordinary Swift calls, not global memoization. Optional nil is a cached value, not a cache miss.
- Getters must depend deterministically on committed snapshot inputs. Ambient time/locale/dependencies require explicit state inputs or a separately approved migration policy.

The registrar publishes all cache clears/updates and prunes removed IDs before notifying a deduplicated snapshot of existing signals. Synchronous Observation willSet callbacks see the new stored snapshot and coherent fresh derived outputs. No commit cache writes occur after notification delivery. Observation still delivers willSet synchronously; there is no didSet guarantee. Direct registrar commit reentrancy is guarded. PR 2 must preserve the existing host's isSending buffering rather than add a second action queue.

## Retained projections

Fresh absent optional/case/row reads return nil. Held projections use their creation snapshot while absent, without trapping or reading/writing live derived caches from stale data. Snapshot mode propagates through descendants. Reappearance resolves the current value, and removed rows lose their live caches. An absent held reader registers the parent shape where appropriate so a later reappearance can be observed. This introduces no effect cancellation, task generations, or structural lifetimes.

## Validation

On Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), Swift language mode 6, Xcode 27.0/macOS SDK 27.0:

- Real macro metadata gate: generic scalar and structural descriptors, inline/bound reads, hidden/raw/composed-path rejection, public/internal/package/private(set) access. Positive ordinary-import clients are diagnostic-free; no generic isolated-conformance warning.
- `scripts/test-feature-state-compile-fixtures.sh`: one runner, isolated module names/package boundaries, positive clients and intended-diagnostic negative fixtures. Negative sources are outside automatically built test targets.
- FeatureStateMacroTests: expansion and diagnostics. FeatureStateRuntimeTests: actual withObservationTracking, publication coherence, caching/equality/getter counts, stored granularity, coarse computed structures, retained absent/reappearing snapshots and row pruning.
- Baseline and changed full suites exercised using both unchanged manifest paths in isolated copies, on Swift 6.4. Macro artifact rebuilt with the existing script.
- Old Todos, FineGrained, and ScopedComposition packages tested on macOS; all five existing example products built for iOS simulator. Search stale-response/debounce tests passed on iOS simulator. TimerLeak's existing test target contains zero tests.

Historical Swift 6.0 and Swift 6.2 compilers were **not run** (unavailable; user approved continuing without them). A 6.2 manifest on Swift 6.4 is not historical compiler evidence. CocoaPods quick podspec lint passed, but consumer `pod lib lint` could not resolve the existing pinned `swift-identified-collections (= 0.1.0)` podspec, so that build is unpassed. Distribution/dependency policy was not changed. Independent external review and manual example interaction remain outstanding.

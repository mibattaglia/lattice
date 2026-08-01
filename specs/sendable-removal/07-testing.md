# Plan 07 — Testing Rewrite

Workstream 7 of `specs/sendable-removal/` (see `README.md` for the pinned contract). This is a
load-bearing plan: it kills the 779-line production-pipeline mirror inside `TestViewModel` by
hosting the **same `LatticeCore` as production** (plan 02) with a test commit strategy, and
replaces the action-receive assertion contract with snapshot-diff assertions in the TCA26
`TestCore`/`TestStore` style.

> **State as of plan 06's flip:** plan 06's deletion commit already removed the legacy test
> host's uncompilable sources (`TestViewModel.swift`, `PendingReceive.swift`,
> `InFlightEffectRecord.swift`, `RootSendOrigin.swift`, `TestEventTask.swift`,
> `Exhaustivity.swift`) and their driving suites (`Tests/LatticeTests/TestingInfrastructureTests/`,
> the `CounterInteractors` fixtures), since they consumed the deleted Emission pipeline.
> `TestFailure.swift` and `TestIssueReporting.swift` were kept (they compile standalone).
> This plan therefore *recreates* the test host files rather than reworking them in place.

Spelling note: this plan **adopts plan 09's spellings verbatim** — `send(_:changes:)`,
`expect(changes:)`, `receive(_:changes:)`, `dismount(timeout:)` — so no mechanical sync of 08 is
required. Divergences from 08's sketches are listed in §10.

---

## 1. Overview

### Today

`Sources/Lattice/Testing/TestViewModel/TestViewModel.swift` (779 lines) re-implements the entire
production pipeline: its own `bufferedActions: Deque`, `rootScopes`, `effectTasks`,
`inFlightEffects`, `isSending` reentrancy flag, and its own copies of the
`EffectTaskRegistry`/`EffectCancellationRegistry`. The contract is action-based: emissions emit
actions, the test buffers them as `PendingReceive`s, and tests consume them with
`receive(.loaded(41)) { $0.count = 42 }`. Scheduling is papered over with five
`Task.megaYield()` call sites.

Both problems die together:

- **The mirror dies** because `TestViewModel` hosts plan 02's `LatticeCore` directly — the same
  core `ViewModel` hosts — differing only in what it installs into the core's two hooks
  (`onCommit`, `onEffectLaunched`). One engine, two commit strategies.
- **`megaYield` dies** because plan 02's deferred-effect-launch + immediate task start
  (`Task.immediateIfAvailable`) makes effect startup synchronous-to-first-suspension and
  deterministic, and `send` returns a composite task over its launched effects rather than the
  old 1 ms
  polling loop. There is nothing left to yield *for*.

### The new contract

Effects no longer emit actions; they commit state via `effectState.modify` (and occasionally
re-enter via `effectState.send`). So the test contract becomes commit-based:

| Assertion | What it covers |
|---|---|
| `send(.action) { $0.count = 1 }` | the synchronous update-phase mutation of a send |
| `await expect { $0.data = [...] }` | the **next** effect-phase commit (an `effectState.modify`) |
| `await receive(.loaded) { $0.count = 42 }` | an `effectState.send` re-entry: matches the action **and** asserts its update-phase mutation |
| `await eventTask.finish()` / `await finish()` | quiescence (plan 06 semantics: the send's directly launched effects) |
| `await dismount()` | teardown; cancels buckets (outstanding event tasks complete as effects wind down) |

Exhaustivity (`.on`, the default): **every commit and every effect-send re-entry must be
asserted before the next `send` and before deinit.** Unasserted pending items fail at deinit,
exactly as unconsumed `PendingReceive`s do today. `.off` skips silently.

Assertion mechanics are snapshot-diff: apply the `changes` closure to the *asserted* state copy,
compare against the actually-committed state with `==` — **the domain state type must be
`Equatable`**; the deleted `areStatesEqual` strategies (plan 05) have no test-side replacement —
and report mismatches with CustomDump's `diff` (already a dependency, `Package.swift:60`) via
`reportIssueHelper` (kept as-is).

### No shims

Every consumer test migrates. The old `receive(action)`-for-emission-output idiom has no
equivalent because the runtime it observed no longer exists. §8 shows the mechanical migration
on a real test from this repo.

---

## 2. The commit-strategy seam (contract with plan 02)

Plan 02 §4 pins the seam; this plan consumes exactly these members and nothing more:

- `init(initialState:isolation:)`, `mount(interact:onCommit:onEffectLaunched:)`,
  `registerPresenceWatcher(path:isPresent:)`
- the `onCommit` hook (a `mount` parameter) `(DomainState, DomainState) -> Void` — **the seam.**
  Production (plans 06/05) installs the `@FeatureState` projection diff
  (`_commit(old:new:registrar:key:)` into the per-ViewModel registrar); the test host installs a
  pending-commit recorder.
- the `onEffectLaunched` hook (a `mount` parameter) — the test host records launches for
  `skipInFlightEffects`-style diagnostics and `hasEffects`.
- `send(_:) throws -> Task<Void, Never>?`, `dismount()` /
  `isDismounted`.

One additional requirement on plan 02 (small, additive — flagged here as a contract point):

> **Commit origin.** `onCommit` must distinguish the three commit origins so the recorder can
> classify pending items: `.send(Action)` (update phase), `.modify`
> (effect phase), `.presenceCancellation`. Plan 02's funnel already has this information at the
> call site; expose it as a third parameter: `onCommit(previous, current, origin)`. Plan 06's
> production hook ignores `origin`. If plan 02 prefers a different encoding, renegotiate via
> README; the recorder needs the origin, nothing else.

With that, the test host in its entirety is: a `LatticeCore`, a recorder installed via the
`onCommit` mount hook, and an assertion queue. No buffering, no scopes, no registries, no drain
loop — that is the 779-line deletion.

---

## 3. New file layout

```
Sources/Lattice/Testing/
  TestViewModel/
    TestViewModel.swift        — rewritten (~250 lines, from 779)
    PendingCommit.swift        — new (replaces PendingReceive.swift, InFlightEffectRecord.swift,
                                 RootSendOrigin.swift)
    TestEventTask.swift        — thin rework (wraps the composite task from core.send; polling wait deleted)
    Exhaustivity.swift         — unchanged
    TestFailure.swift          — rewritten cases (commit-diff messages replace action-buffer messages)
    TestIssueReporting.swift   — unchanged
```

`Sources/Lattice/Testing` stays excluded from `Lattice.podspec` (`s.exclude_files`, line 17) —
no podspec change. *As landed:* `Package.swift` adds the `DequeModule` product of the
already-present `swift-collections` dependency (the recorder's `Deque`).

Deleted:

```
Sources/Lattice/Testing/TestViewModel/PendingReceive.swift
Sources/Lattice/Testing/TestViewModel/InFlightEffectRecord.swift
Sources/Lattice/Testing/TestViewModel/RootSendOrigin.swift
Tests/LatticeTests/TestingInfrastructureTests/TestViewModelObserveTests.swift   (contract gone)
Tests/LatticeTests/TestingInfrastructureTests/TestViewModelAppendTests.swift    (Emission gone)
```

The remaining `TestingInfrastructureTests` files are rewritten against the new contract (§9).

---

## 4. `PendingCommit.swift` — new

```swift
/// One unasserted re-entry into the core, captured by the test commit strategy.
enum PendingCommit<DomainState, Action> {
    /// An `effectState.modify` commit: the state as committed.
    case mutation(resulting: DomainState)

    /// An `effectState.send` re-entry: the action, and the state after its update phase.
    case action(Action, resulting: DomainState)

    var resultingState: DomainState {
        switch self {
        case .mutation(let state), .action(_, resulting: let state):
            return state
        }
    }
}
```

> **§10 sync point resolved (implementation):** the landed core never commits on pure
> presence cancellation — transition detection runs *inside* the funnel of the mutation that
> flipped the presence, and a scoped-drop `modify` runs no funnel pass at all — so the
> sketched `.presenceCancellation` case was dead code and is dropped, as this plan flagged.

No `Sendable`, no constraints — everything is confined to the test host's isolation (MainActor),
per the pinned contract.

---

## 5. `TestViewModel.swift` — rewritten

Full public surface (bodies elided only where they are one-line forwards to helpers shown):

```swift
import DequeModule
// (No Clocks import: Duration/ContinuousClock are stdlib; TestClock stays a consumer tool.)

/// A domain-state-first testing host for a Lattice feature.
///
/// `TestViewModel` hosts the same core engine as ``ViewModel`` — same commit funnel, same
/// effect launch, same cancellation semantics — installing a recording commit strategy in
/// place of the production projection diff (`_commit` into the registrar, plan 05). The
/// contract is step-wise and exhaustive:
///
/// - ``send(_:changes:fileID:file:line:column:)`` asserts the update-phase mutation.
/// - ``expect(changes:timeout:fileID:file:line:column:)`` asserts the next `effectState.modify` commit.
/// - ``receive(_:changes:timeout:fileID:file:line:column:)`` asserts the next `effectState.send`
///   re-entry and its update-phase mutation.
/// - Under ``Exhaustivity/on``, unasserted commits fail at deinit.
///
/// `DomainState: Equatable` is required: snapshot-diff assertions compare with `==`.
@MainActor
public final class TestViewModel<DomainState: Equatable, Action> {
    /// The most recently asserted domain state.
    public private(set) var domainState: DomainState

    /// Controls whether pending commits must be asserted before later sends and deinit.
    public var exhaustivity: Exhaustivity = .on

    /// The default timeout used by APIs that accept an optional timeout.
    public var timeout: Duration = .seconds(1)

    private let core: LatticeCore<DomainState, Action>
    // 'nonisolated(unsafe)' solely for the deinit backstop (compiler-forced: a nonisolated
    // deinit may not read a non-Sendable isolated property); every other access is
    // MainActor-isolated, and deinit runs with exclusive access.
    private nonisolated(unsafe) var pendingCommits: Deque<PendingCommit<DomainState, Action>> = []
    // Parked continuations resumed by the recorder, NOT an AsyncStream: cancelling an
    // AsyncStream consumer (the timeout race) terminates the stream, breaking every later
    // wait. `domainState` doubles as the asserted-state baseline.
    private var commitWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init(
        initialDomainState: DomainState,
        interactor: some Interactor<DomainState, Action>
    ) {
        self.domainState = initialDomainState
        self.core = LatticeCore(initialState: initialDomainState, isolation: MainActor.shared)
        // Same mount call as ViewModel: the root effects handle walks the interactor tree
        // from the root path (plan 04's landed spelling; the sketched `interactor.route`
        // never existed), and the snapshot recorder is installed as the commit hook. (This
        // host uses the origin-extended onCommit — renegotiated onto plan 02, see Risks.)
        let rootEffects = _makeEffectsHandles(core: core, lens: .identity, path: GraphPath())
        core.mount(
            interact: { state, action in
                interactor.interact(state: &state, action: action, effects: rootEffects)
            },
            onCommit: { [weak self] previous, current, origin in
                self?.record(previous: previous, current: current, origin: origin)
            },
            onEffectLaunched: { [weak self] _, task in
                self?.launchedEffectTasks.append(task)   // finish/dismount quiescence
            }
        )
    }

    deinit {
        // Under exhaustivity .on, unasserted commits fail at deinit. Core teardown (bucket
        // cancellation) happens in the core storage's own deinit —
        // TestViewModel has no other teardown.
        if exhaustivity == .on, !pendingCommits.isEmpty {
            reportIssueHelper(
                TestFailure.unassertedCommitsAtDeinit(pendingCommits).message,
                at: .init(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
            )
        }
    }

    // MARK: Send

    /// Sends an action and asserts the synchronous update-phase mutation via snapshot diff.
    @discardableResult
    public func send(
        _ action: Action,
        changes: ((inout DomainState) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestEventTask {
        let location = TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)

        if exhaustivity == .on, !pendingCommits.isEmpty {
            reportTestFailure(
                TestFailure.mustAssertCommitsBeforeSending(pendingCommits), at: location)
            return TestEventTask(rawValue: nil, timeout: timeout)
        }

        let sendTask: Task<Void, Never>?
        do {
            sendTask = try core.send(action)
        } catch {
            reportTestFailure(TestFailure.sendAfterDismount(action), at: location)
            return TestEventTask(rawValue: nil, timeout: timeout)
        }

        // The update-phase commit for our own send is consumed immediately, not queued:
        // pop the .send-origin commit the recorder just captured and diff it.
        assertPoppedSendCommit(changes: changes, at: location)
        return TestEventTask(rawValue: sendTask, timeout: timeout)
    }

    // MARK: Expect (effectState.modify commits)

    /// Asserts the next effect-phase commit (an `effectState.modify`) via snapshot diff,
    /// waiting up to `timeout` for one to arrive.
    public func expect(
        changes: ((inout DomainState) throws -> Void)? = nil,
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        let location = TestIssueLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        guard let commit = await nextPendingCommit(timeout: duration ?? timeout, at: location) else {
            reportTestFailure(TestFailure.expectedCommit(timeout: duration ?? timeout), at: location)
            return
        }
        guard case .mutation(let resulting) = commit else {
            reportTestFailure(TestFailure.expectedMutationButReceivedAction(commit), at: location)
            return
        }
        assertDiff(changes: changes, against: resulting, at: location)
    }

    // MARK: Receive (effectState.send re-entries)

    /// Asserts the next `effectState.send` re-entry: the action must match, and `changes`
    /// asserts its update-phase mutation.
    public func receive(
        _ expectedAction: Action,
        changes: ((inout DomainState) throws -> Void)? = nil,
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async where Action: Equatable { /* matcher wrapper over receive(matching:) */ }

    #if canImport(CasePaths)
    /// Case-path variant of ``receive(_:changes:timeout:fileID:file:line:column:)``: matches
    /// the next `effectState.send` re-entry against the given case of `Action`.
    public func receive<Value>(
        _ actionKeyPath: KeyPath<Action.AllCasePaths, AnyCasePath<Action, Value>>,
        changes: ((inout DomainState) throws -> Void)? = nil,
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async { /* extract-and-match wrapper */ }
    #endif

    // MARK: Skipping / quiescence

    /// Consumes all pending commits without asserting them (non-exhaustive escape hatch).
    public func skipPendingCommits(
        fileID: StaticString = #fileID, file filePath: StaticString = #filePath,
        line: UInt = #line, column: UInt = #column
    )

    /// Waits for every in-flight effect task to complete.
    public func finish(
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID, file filePath: StaticString = #filePath,
        line: UInt = #line, column: UInt = #column
    ) async

    /// Dismounts the feature: cancels every task bucket (outstanding event tasks complete as
    /// the cancelled effects wind down) and (exhaustivity .on) fails on unasserted commits.
    public func dismount(
        timeout duration: Duration = .zero,
        fileID: StaticString = #fileID, file filePath: StaticString = #filePath,
        line: UInt = #line, column: UInt = #column
    ) async
}
```

### Internals worth pinning

**The recorder** (installed via `core.mount(onCommit:)`):

```swift
private func record(previous: DomainState, current: DomainState, origin: CommitOrigin<Action>) {
    switch origin {
    case .send(let action):
        if isOwnSendInProgress {
            // Consumed synchronously by send(_:changes:); parked in a one-slot buffer. The
            // flag clears HERE — on the first .send-origin commit — so a synchronous
            // effect-prefix 'effectState.send' re-entry (which fires before core.send
            // returns) queues as pending instead of overwriting the parked commit.
            ownSendCommit = current
            isOwnSendInProgress = false
        } else {
            pendingCommits.append(.action(action, resulting: current))
        }
    case .modify:
        pendingCommits.append(.mutation(resulting: current))
    }
    // resume every parked commit waiter with `true`
}
```

**Snapshot diff** (`assertDiff`): apply `changes` to a copy of `domainState` (the asserted
baseline); if
`expected != actual` (plain `Equatable` — no equality strategy to configure), report
`TestFailure.stateMutationDidNotMatchExpectation` carrying
`CustomDump.diff(expected, actual)` output (format matching TCA26 `TestCore.swift:1638-1706`'s
expected/actual framing). On completion, `domainState = actual` (mismatch or not, so one
failure does not cascade). A
`changes: nil` call asserts *no visible change* — same convention as today's `send` with no
trailing closure and TCA26's `send(_:)` non-asserting overload, but exhaustive mode still
requires the commit to be *consumed*.

**Waiting** (`nextPendingCommit(until:)`): if `pendingCommits` is non-empty, pop immediately.
Otherwise park a continuation resumed by the recorder on the next commit, raced against a
`ContinuousClock` deadline task (or `TestClock` if
injected via the effect under test — the clock is the consumer's, not ours). No `megaYield`:
commits are signaled synchronously by the funnel, and effect sync-prefixes have already run by
the time `send` returns (plan 02 §5 effect-ordering guarantee).

Under `.off` exhaustivity, `expect`/`receive` skip non-matching pending commits silently,
advancing `domainState` to each skipped commit's resulting state so the next snapshot diff
baselines correctly.

### View-layer assertions

There is no `viewState` property and no ViewState fixture to construct. When the domain state
is a `@FeatureState` type (plan 05), view assertions read the generated projection — the same
surface a view reads, compile-checked against the visible members:

```swift
#expect(testViewModel.projection.subtitle == "3 results")
```

`projection` is exposed via a conditional extension (`DomainState: FeatureStateProtocol`) that
reads the committed state; domain-only tests never touch it, and the test host leaves `_commit`
unwired — `onCommit` carries the recorder instead. Each access builds a **fresh registrar**, so
derived members always compute from current committed state (a persistent registrar's
derivation cache would go stale with `_commit` unwired). Projection/registrar behavior itself
(granularity, `RecordingRegistrar`) is tested in plan 05's workstream, not here.

---

## 6. `TestEventTask.swift` — thin rework

Shape preserved (`cancel()`, `finish(timeout:)`, `isCancelled`, `hasEffects`); implementation
becomes a wrapper over the composite task returned by `core.send`, with plan 06's EventTask
semantics (the send's directly launched effects) — the current implementation's polling wait
and effect-record bookkeeping are
deleted. `TestEventTask` stays `Sendable` (it wraps a `Task` handle, consistent with plan 06
keeping `EventTask: Sendable`).

```diff
-public struct TestEventTask: Sendable {
-    let rawValue: EventTaskBox?
+public struct TestEventTask: Sendable {
+    let rawValue: Task<Void, Never>?     // composite task returned by core.send
     let timeout: Duration
```

`finish(timeout:)` keeps its diagnostic: if the composite task does not complete within the
timeout, report `TestFailure.expectedTaskToFinish` and cancel the still-running effects (the
old `cancellableValue` race semantics). *As landed:* the message does **not** name in-flight
`(GraphPath, Location)` keys — `TestEventTask` is `Sendable` and cannot hold the non-Sendable
core, and the core exposes no key-enumeration API; add one if the diagnostic proves needed.

---

## 7. `InteractorTestHarness` and `AsyncStreamRecorder` — verdict

**They do not exist.** `AGENTS.md` and `CLAUDE.md` reference both, but a repo-wide grep finds no
source: there is no `InteractorTestHarness` or `AsyncStreamRecorder` anywhere under `Sources/`
or `Tests/`. The references are stale docs.

Verdict: **do not build a harness.** With the shared core, `TestViewModel` *is* the interactor
harness — it drives the real funnel, real effect launch, real cancellation, with deterministic
assertions. A separate state-box harness driving `interact` directly would re-create a second
engine, which is precisely the disease this plan cures. Plan 09 should remove the stale
mentions from `AGENTS.md`/`CLAUDE.md` (handoff noted in §10).

**`TestClock`**: survives untouched. It comes from `swift-clocks` (already a `Lattice` target
dependency, `Package.swift:59`), and remains the tool for testing the debounce-by-replacement
idiom (`clock.sleep` inside `effects.perform`, plan 03 §Usage examples).

---

## 8. Migration example — no shims

From `Tests/LatticeTests/TestingInfrastructureTests/TestViewModelSendTests.swift` (real file,
abridged):

**Before** (interactor + test, current API):

```swift
@Interactor<TestSendState, TestSendAction>
private struct TestSendInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .load:
                state.count += 1
                return .perform { .loaded(41) }
            case .loaded(let value):
                state.count += value
                return .none
            // ...
            }
        }
    }
}

@Test
func sendBuffersEmittedActionsUntilReceive() async {
    let model = makeModel()
    let task = await model.send(.load) { $0.count = 1 }
    #expect(task.hasEffects)
    await model.receive(.loaded(41)) { $0.count = 42 }
    #expect(model.domainState.count == 42)
}
```

**After** (new API; note the `.loaded` action and the ping-pong disappear from the *feature*,
so the test asserts a commit, not an action):

```swift
@Interactor<TestSendState, TestSendAction>
private struct TestSendInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .load:
                state.count += 1
                effects.perform { $0.count += 41 }
            // no .loaded re-entry case — the effect commits state directly
            // ...
            }
        }
    }
}

@Test
func sendCommitsEffectMutationsForAssertion() async {
    let model = makeModel()
    let task = await model.send(.load) { $0.count = 1 }
    #expect(task.hasEffects)
    await model.expect { $0.count = 42 }
    #expect(model.domainState.count == 42)
}
```

Features that keep `effectState.send` re-entries (parent notification patterns) migrate their
`receive` calls nearly unchanged — `receive(.childFinished) { ... }` keeps its spelling, only
its meaning shifts from "buffered emission output" to "effectState.send re-entry".

Old → new mapping table (consumer-facing; feeds plan 09's migration guide):

| Old | New |
|---|---|
| `send(_:assert:)` | `send(_:changes:)` — role unchanged |
| `receive(action, assert:)` for `.perform`/`.observe` output | `expect(changes:)` per `effectState.modify` commit |
| `receive(action, assert:)` for genuine re-entries | `receive(_:changes:)` — kept |
| `receive(matching:)` / case-path overloads | case-path `receive` kept; predicate overload dropped (YAGNI — add back on demand) |
| `skipReceivedActions()` | `skipPendingCommits()` |
| `skipInFlightEffects()` | deleted — `dismount()` or `TestEventTask.cancel()` covers the intent |
| `finish(timeout:)` | kept, same shape |
| `Exhaustivity.on/.off` | kept, same shape; scope extends from actions to commits |

---

## 9. Test-suite impact (this repo)

- `TestingInfrastructureTests/*` — rewritten against the new contract; `...ObserveTests` and
  `...AppendTests` deleted (asserted Emission mechanics). `...SendTests`, `...CancellationTests`,
  `...ExhaustivityTests`, `...WaitingTests` keep their *scenarios* with migrated assertions.
- `DomainTests/Emission*` — deleted (workstream 4 owns the source deletions; tests go with them).
- `InternalTests/EmissionExecutionTests.swift` — deleted; replaced by plan 02 §8's core suite.
- New: `TestingInfrastructureTests/TestViewModelExpectTests.swift` covering: expect happy path,
  expect timeout failure, mutation-vs-action mismatch failure, exhaustivity-at-deinit failure
  (via `withKnownIssue`), presence-cancellation visibility, `changes: nil` no-change assertion.

## Acceptance gates

```bash
swift build                                        # both runtimes coexist until WS5 flip; then clean
swift test --filter TestingInfrastructureTests     # new contract green
swift test                                         # full suite green post-migration
grep -rn "megaYield" Sources Tests                 # zero hits
grep -rn "PendingReceive\|InFlightEffectRecord\|RootSendOrigin" Sources && exit 1  # deleted
grep -rn "areStatesEqual\|ViewStateReducer\|ObservableState" Sources/Lattice/Testing Tests/LatticeTests/TestingInfrastructureTests && exit 1  # reducer-era surface gone (plan 05)
wc -l Sources/Lattice/Testing/TestViewModel/TestViewModel.swift   # ~250, not 779
grep -n "exclude_files" Lattice.podspec            # Testing still excluded
```

## Risks

1. **`onCommit` origin parameter is a new ask on plan 02.** Small and additive, but it must
   land there before this plan's implementation starts. (Renegotiation path: README.)
2. **Own-send commit capture** (the `isOwnSendInProgress` one-slot buffer) depends on plan 02's
   guarantee that the update-phase commit fires synchronously inside `core.send` before any
   effect commit can interleave. Plan 02 §5's funnel ordering states this; a core unit test
   should pin it (added to plan 02 §8's list).
3. **Effect sync-prefix commits.** Plan 02 lets an effect body `modify` synchronously before its
   first suspension, *during* `send`'s effect-launch step. Those commits arrive while `send` is
   still on the stack — the recorder handles this (they queue as `.mutation`), but test authors
   may be surprised that `expect` succeeds without any awaiting. Document in the API docs.
4. **Timeout flakiness** is inherited, not new — but the continuation-signaled wait plus
   immediate effect start should make the default 1 s timeout effectively never load-bearing.
5. **Deinit-time reporting** from a `deinit` context relies on `reportIssueHelper` being safe
   off-MainActor; today's deinit does registry cancellation only. Mitigation: mirror TCA26's
   deinit-reporting approach (`TestCore` reports from its own teardown, not the class deinit)
   by preferring `dismount()` in tests and treating deinit reporting as the backstop.

## §10 Sync points with sibling plans

- **Plan 02**: *resolved in this plan's implementation* — `origin` added to `onCommit`
  (`CommitOrigin<Action>`: `.send(Action)` / `.modify`), production hook ignores it; pure
  presence-cancellation produces no commit, so `PendingCommit.presenceCancellation` was
  dropped (§4).
- **Plan 06**: quiescence/EventTask semantics (direct-effects-only coverage) consumed as
  written (no divergence).
- **Plan 05**: projection/registrar unit tests (granularity, `RecordingRegistrar`) live there;
  this plan only exposes projection reads on the test host and requires `Equatable` on the
  domain state (the deleted `areStatesEqual` strategies have no test-side replacement).
- **Plan 09**: spellings adopted verbatim (`send(_:changes:)`, `expect(changes:)`,
  `receive(_:changes:)`, `dismount(timeout:)`) — **no sync needed**, except: 08 should note
  that the predicate `receive(matching:)` overload is dropped, `skipReceivedActions` →
  `skipPendingCommits`, `skipInFlightEffects` is deleted, and the stale
  `InteractorTestHarness`/`AsyncStreamRecorder` mentions in `AGENTS.md`/`CLAUDE.md` must be
  removed.

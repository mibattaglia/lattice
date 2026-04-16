# TestViewModel Issue Reporting Plan

## Goal

Move `TestViewModel` and `TestEventTask` away from public thrown assertion failures and toward
TCA-style issue reporting that:

- records failures at the user call site using `fileID`/`filePath`/`line`/`column`
- keeps step-wise test semantics unchanged
- preserves detailed state/action diffs
- uses Lattice terminology (`Emission`, `emitted action`) in user-facing copy
- uses conditional imports so SwiftPM testing consumers get the rich path without forcing the same
  dependency story on CocoaPods production consumers

## Decision summary

The public testing APIs should stop surfacing assertion failures as thrown `Error`s.
Instead, they should record issues at the assertion site, like TCA's `TestStore`.

This means:

- `send`, `receive`, `finish`, `skipReceivedActions`, `skipInFlightEffects`, and
  `TestEventTask.finish` should become non-throwing assertion APIs.
- existing location metadata should be used structurally when reporting issues, not printed into
  failure strings
- `TestFailure` should become an internal diagnostic builder or be deleted entirely
- Lattice's own tests should stop catching thrown failures and instead assert on recorded issues
- `IssueReporting` and `CustomDump` should be used conditionally
- SwiftPM consumers should get the full TCA-like diagnostics path
- CocoaPods consumers should compile without these testing-oriented dependencies, even if that path
  has weaker diagnostics

## Why change this

Today `TestViewModel` has TCA-shaped APIs on the surface, but the failure model is still different:

- failures are thrown as `TestFailure`
- many public APIs capture location metadata but do not use it
- tests need wrappers that catch failures instead of asserting on recorded issues
- the current behavior encourages plumbing `throws` through helper layers that are meant to behave
  like assertions

TCA uses location metadata because it does not want the failure to point at internal helper code.
It records the issue at the original `send`/`receive`/`finish` call site.

That is the behavior Lattice should copy.

## TCA grounding

TCA's `TestStore`:

- accepts `fileID`/`filePath`/`line`/`column` on public testing APIs
- threads them through helper layers
- reports failures with `reportIssue(...)`
- keeps rich `CustomDump` diffs in the message body
- does not put raw file/line text inside the error description

That is the right split:

- message text explains the failure
- issue reporting controls where the failure is attributed

## Current Lattice gaps

### 1. Public assertions still throw

`TestViewModel.send`, `receive`, `finish`, `skipReceivedActions`, `skipInFlightEffects`, and
`TestEventTask.finish` currently use thrown failures as their public contract.

### 2. Location metadata is mostly dead weight

Several public APIs accept location metadata but only pass it through unused private helpers.

### 3. `TestEventTask.finish` cannot attribute failures to the caller

It currently accepts only `timeout`, so timeout failures cannot be pinned to the user's
`task.finish()` line.

### 4. Lattice tests are validating thrown errors, not reported issues

The current support helpers catch `TestFailure` and inspect its string form.

### 5. User-facing copy is mixed

Some recent diagnostics still say "effect" where Lattice should say "emission".

## Scope

### In scope

- `TestViewModel` public assertion API behavior
- `TestEventTask.finish`
- diagnostic plumbing and message attribution
- internal test support updates
- package/dependency wiring needed for issue reporting and rich diffs
- README / skill / inline doc updates for non-throwing test examples

### Out of scope

- changing step-wise buffering semantics
- changing exhaustivity semantics
- changing how root scopes or pending receives are tracked
- changing `ViewModel` production behavior

## Proposed design

### 1. Adopt conditional testing-diagnostics dependencies

Use `IssueReporting` as the reporting primitive and `CustomDump` for rich diffs when those modules
are available, mirroring TCA as closely as possible under SwiftPM.

Dependency policy:

- add `IssueReporting` to `Package.swift`
- add it to `Package@swift-6.2.swift`
- keep `IssueReporting` imported with `#if canImport(IssueReporting)`
- keep `CustomDump` imported with `#if canImport(CustomDump)`
- do not require either dependency from `Lattice.podspec`

Why this split:

- SwiftPM is the primary path for Lattice testing consumers
- CocoaPods consumers are primarily production consumers and should not be forced to resolve
  testing-oriented dependencies
- conditional imports let Lattice compile in both worlds while still giving SwiftPM users the
  TCA-like experience

SwiftPM path:

- full TCA-like attribution with `reportIssue(...)`
- `CustomDump` diffs in diagnostic messages

Fallback path when modules are unavailable:

- keep the public APIs non-throwing
- route failures through a small internal fallback reporter
- do not promise full parity for this path

Test work:

- add `IssueReportingTestSupport` to `LatticeTests` if needed for expected-issue assertions

### 2. Make public testing APIs non-throwing

Target public signatures:

```swift
@discardableResult
public func send(...) async -> TestEventTask

public func receive(...) async

public func finish(...) async

public func skipReceivedActions(...) async

public func skipInFlightEffects(...) async

public func TestEventTask.finish(...) async
```

This is a source-breaking change because user tests will remove `try`.

That is acceptable and desirable:

- these APIs are assertion APIs, not recoverable operations
- TCA users do not expect to handle assertion failures with `catch`
- public `throws` here actively pushes consumers toward the wrong model

### 3. Keep internal throwing only if it helps control flow

We do not need to ban `throws` internally.

TCA still uses internal throwing helpers in places. Lattice can do the same.

Recommended boundary:

- internal helpers may still `throw TestFailure` or another internal diagnostic type
- public APIs should catch those failures immediately and call `reportIssue(...)`
- no public testing API should require `try`

This keeps implementation simple while changing the user-facing contract.

### 4. Add private reporting and formatting helpers for `TestViewModel`

Introduce a small internal shim so the public testing APIs have one reporting path.

Recommended pieces:

- `reportIssueHelper(...)`
- `describe(...)`
- `diffMessage(...)`

`reportIssueHelper(...)` should:

- accept the message
- accept `fileID`/`filePath`/`line`/`column`
- use `IssueReporting.reportIssue(...)` when available
- use a fallback mechanism when `IssueReporting` is unavailable
- respect `exhaustivity` if Lattice wants to preserve the same skipped-assertion semantics

Suggested reporting shape:

```swift
private func reportIssueHelper(
  _ message: String,
  fileID: StaticString,
  filePath: StaticString,
  line: UInt,
  column: UInt
)
```

Suggested fallback behavior when `IssueReporting` is unavailable:

- `assertionFailure(message)` in debug builds
- no attempt to perfectly emulate Swift Testing / XCTest issue attribution

If Lattice wants full TCA parity later, this helper can grow an `overrideExhaustivity` parameter.

### 5. Thread location metadata only where it is actually needed

Public APIs should keep location parameters and use them for issue recording.

Private helpers should not carry unused metadata just to preserve old signatures.

Immediate changes needed:

- `send` reports state mismatch / pending receive violations at the `send` call site
- `receive` reports missing or unexpected emitted actions at the `receive` call site
- `finish` reports pending receives or in-flight emissions at the `finish` call site
- `skipReceivedActions` and `skipInFlightEffects` report misuse at their own call site
- `TestEventTask.finish` gains location metadata and reports timeout at the `finish()` call site

### 6. Use root-send origin data for late diagnostics

Lattice already tracks `rootSendOrigins`.

That should become the attribution source for failures discovered after the original `send`
returns, such as:

- emissions still running at teardown
- late unhandled emitted actions associated with a root scope
- root-scope completion problems that outlive the immediate assertion boundary

Immediate caller metadata should still win for direct assertion APIs like `finish()` and
`task.finish()`.

### 7. Rework `TestFailure`

`TestFailure` should no longer be a public assertion surface.

Recommended path:

- make it `internal`
- keep it as a small message factory if that remains useful
- or replace it with internal helper functions returning strings

The important change is that consumers should no longer catch it.

### 8. Keep rich diff formatting

The current `CustomDump` integration should remain when the module is available:

- state mismatch failures should continue to show proportional diffs
- exact `receive` mismatches should continue to diff expected vs received action
- action list formatting should stay readable

When `CustomDump` is unavailable, fall back to plain `Expected:` / `Actual:` formatting.

This change is orthogonal to issue reporting, but both together define the full TCA-like path.

### 9. Normalize user-facing terminology

All public diagnostics and docs in the testing layer should say:

- `emission`
- `emitted action`
- `in-flight emissions`

Avoid `effect` in Lattice-facing copy.

## Public API migration

### Before

```swift
let task = try await model.send(.load) {
  $0.count = 1
}

try await model.receive(.loaded(42)) {
  $0.count = 42
}

try await task.finish()
```

### After

```swift
let task = await model.send(.load) {
  $0.count = 1
}

await model.receive(.loaded(42)) {
  $0.count = 42
}

await task.finish()
```

## File changes

### `Package.swift`

- add `IssueReporting` dependency and target product wiring
- keep `CustomDump` dependency for the rich diagnostics path

### `Package@swift-6.2.swift`

- add matching `IssueReporting` dependency and target product wiring
- keep matching `CustomDump` dependency

### `Lattice.podspec`

- do not add `IssueReporting`
- do not add `CustomDump`
- rely on conditional imports so CocoaPods production consumers compile without the testing-only
  diagnostics path

### `Sources/Lattice/Testing/TestViewModel/TestViewModel.swift`

- remove public `throws`
- catch internal failures and report issues at the supplied source location
- delete unused metadata plumbing in private helpers
- keep helpers private
- normalize terminology to `emission`
- use conditional issue-reporting plumbing rather than assuming the dependency is always present

### `Sources/Lattice/Testing/TestViewModel/TestEventTask.swift`

- add location metadata to `finish`
- convert timeout failure from thrown error to recorded issue

### `Sources/Lattice/Testing/TestViewModel/TestFailure.swift`

- make internal or delete
- keep only as an internal message builder if needed
- keep `CustomDump` usage conditional

### `Tests/LatticeTests/TestingInfrastructureTests/TestViewModelTestSupport.swift`

- replace catch-based helpers with expected-issue helpers

### `Tests/LatticeTests/TestingInfrastructureTests/*`

- remove `try`
- assert on recorded issues rather than caught errors
- validate the rich SwiftPM path, since that is the parity target

### `README.md`

- update any `TestViewModel` examples to the non-throwing style

### `skills/lattice-testing/SKILL.md`

- update examples and wording to match the new contract

## Test plan

### Update existing tests

- replace `expectTestFailure(...)` catch-based assertions with issue-based assertions
- remove `try` from step-wise `TestViewModel` usage

### Add focused regression tests

- `send` mismatch records an issue at the `send` site
- exact `receive` mismatch records an issue at the `receive` site
- `finish` pending-receive failure records at the `finish` site
- `TestEventTask.finish` timeout records at the task-finish site
- skipped helper misuse (`skipReceivedActions`, `skipInFlightEffects`) records at the helper call
  site

### Keep existing semantic coverage

- buffering behavior
- exhaustivity behavior
- append / observe behavior
- cancellation behavior
- debounce behavior

## Risks

### Risk 1: hidden semantic drift during the migration

If the implementation changes both failure transport and runtime semantics in one pass, behavior
could drift.

Mitigation:

- keep the step-wise runtime untouched
- change only the failure boundary first

### Risk 2: half-migrated public API

If some methods still throw and others report issues, the testing surface becomes inconsistent.

Mitigation:

- migrate the full public testing surface in one PR

### Risk 3: call-site attribution regressions

If location metadata is not threaded all the way to `reportIssue`, failures will point at helpers.

Mitigation:

- add focused tests around failure attribution
- do not keep unused metadata parameters in private helpers

### Risk 4: over-coupling to TCA naming or copy

Lattice should copy the behavior, not TCA's terminology.

Mitigation:

- preserve Lattice terminology in all user-facing strings

### Risk 5: fallback path becomes an accidental supported contract

If the no-`IssueReporting` / no-`CustomDump` path is treated as first-class, implementation
complexity will grow quickly.

Mitigation:

- define SwiftPM as the parity target
- keep fallback behavior minimal and clearly best-effort

## Open questions

### 1. Should `TestFailure` survive internally?

Recommended answer:

- yes, initially, as an internal helper type
- no, as a public type

### 2. Should `TestViewModel` support skipped-assertion reporting identical to TCA?

Recommended answer:

- not required for phase 1
- add only if the current exhaustivity model needs the same issue-wrapping behavior

### 3. Should `CustomDump` stay conditional?

Recommended answer:

- yes
- SwiftPM should keep the rich path
- CocoaPods should compile without inheriting this testing-only dependency story

### 4. Should `IssueReporting` be conditional too?

Recommended answer:

- yes
- SwiftPM should get the TCA-like attribution path
- CocoaPods should compile without taking a hard dependency on issue-reporting infrastructure

## Phases

### Phase 1: Add conditional diagnostics dependencies and helper

- add `IssueReporting` to SwiftPM package manifests
- add a private `reportIssueHelper` in the testing layer
- do not add `IssueReporting` or `CustomDump` to `Lattice.podspec`

### Phase 2: Convert `TestViewModel` public APIs

- remove public `throws`
- catch internal failures and report at the caller location

### Phase 3: Convert `TestEventTask.finish`

- add location metadata
- report timeout failures instead of throwing

### Phase 4: Migrate tests

- replace catch-based failure assertions
- add attribution-focused regression coverage

### Phase 5: Docs and cleanup

- update README
- update `lattice-testing` skill
- make `TestFailure` internal or delete it

## Recommended first PR

Do this in one focused pass:

1. Add `CustomDump` and `IssueReporting` only to the SwiftPM manifests, not `Lattice.podspec`.
2. Keep `IssueReporting` and `CustomDump` conditional in the testing layer.
3. Convert only the public `TestViewModel` / `TestEventTask` assertion APIs to issue reporting.
4. Keep `TestFailure` internal for now.
5. Migrate the testing-infrastructure tests first.

That gets the biggest user-facing win with the least semantic churn.

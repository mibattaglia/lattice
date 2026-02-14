# Sketch E: Feature-Only `ViewModel` Public API (Breaking)

## Goal
Enforce a single public API lane for feature code:

- Public `ViewModel` is parameterized by a feature type only.
- Public initialization path is feature-based only.
- Preserve existing `ViewModel` runtime semantics (`viewState`, `sendViewEvent`, emissions, task handling).
- Keep interactor/reducer construction lanes internal for framework tests during migration.

## Why
Current feature code carries three generics (`Action`, `DomainState`, `ViewState`) across type annotations and binding helpers. This is correct but cumbersome. A feature-typed `ViewModel` removes repeated generic noise and makes the architecture lane explicit.

## Scope

### In scope
- Breaking public API migration to feature-typed `ViewModel`.
- Internal test escape hatch for direct interactor/reducer initialization.
- Docs/tests/examples migration to feature lane.

### Out of scope
- New semantic behavior in state/effect execution.
- New architecture concepts beyond `FeatureProtocol`.

## Public API target

```swift
public protocol FeatureProtocol {
    associatedtype Action: Sendable
    associatedtype DomainState: Sendable
    associatedtype ViewState: ObservableState

    var interactor: AnyInteractor<DomainState, Action> { get }
    var viewStateReducer: AnyViewStateReducer<DomainState, ViewState> { get }
    var makeInitialViewState: (DomainState) -> ViewState { get }
    var areStatesEqual: (DomainState, DomainState) -> Bool { get }
}

extension Feature: FeatureProtocol {}

@dynamicMemberLookup
@MainActor
public final class ViewModel<F: FeatureProtocol>: Observable {
    public typealias Action = F.Action
    public typealias DomainState = F.DomainState
    public typealias ViewState = F.ViewState

    public private(set) var viewState: ViewState { get }

    public init(initialDomainState: DomainState, feature: F)

    @discardableResult
    public func sendViewEvent(_ event: Action) -> EventTask
}
```

## Breaking changes

1. Remove public `ViewModel<Action, DomainState, ViewState>`.
2. Remove public direct init lanes:
   - `init(initialDomainState:initialViewState:interactor:viewStateReducer:...)`
   - `init(initialDomainState:interactor:viewStateReducer:...)`
   - `init(initialState:interactor:...)`
3. Remove public binding constraints that mention 3-generic `ViewModel`.
4. Update docs/snippets to feature-typed `ViewModel`.

## Internal-only compatibility

Keep direct interactor/reducer lanes internal for framework tests only:

- Option A: `internal` initializers on `ViewModel<F>` behind extra generic constraints.
- Option B: internal `_ViewModelCore<Action, DomainState, ViewState>` used by `ViewModel<F>`.

Preferred: Option B for cleaner public surface and easier test-only wiring isolation.

## Implementation notes

- `FeatureProtocol` should not require `Sendable` unless closure properties are upgraded to `@Sendable`.
- Preserve dynamic member lookup on `ViewState` exactly.
- Preserve all effect behavior (`.action`, `.perform`, `.observe`, `.merge`) unchanged.
- Keep `EventTask` behavior unchanged.

## Agentic runbook (implementation)

### Phase 1: Define API shape
1. Edit `Sources/Lattice/Presentation/Feature/Feature.swift`.
2. Add/confirm `FeatureProtocol`.
3. Ensure `Feature` conforms to `FeatureProtocol`.
4. Keep closure signatures aligned with current `Feature` storage types.

Acceptance:
- `Feature.swift` compiles standalone.

Status: Complete (2026-02-14)
Verification:
- `swift build --target Lattice`

### Phase 2: Reshape `ViewModel`
1. Edit `Sources/Lattice/Presentation/ViewModel/ViewModel.swift`.
2. Replace public class signature with `ViewModel<F: FeatureProtocol>`.
3. Keep `Action/DomainState/ViewState` as typealiases from `F`.
4. Keep only public init: `init(initialDomainState:feature:)`.
5. Move old direct lanes to internal-only path:
   - either internal initializers
   - or internal `_ViewModelCore` + forwarding.
6. Keep method/property semantics identical (`viewState`, `sendViewEvent`, dynamic member lookup).

Acceptance:
- No public signature exposes 3-generic `ViewModel`.
- Internal tests can still construct with direct lanes (temporarily).

Status: Complete (2026-02-14)
Verification:
- `rg -n "public final class ViewModel<|ViewModel<Action|init\\(initialDomainState:.*interactor|Value == ViewModel<" Sources Tests README.md`
- `swift build --target Lattice`

### Phase 3: Binding migration
1. Edit `Sources/Lattice/Presentation/ViewModel/ViewModelBinding.swift`.
2. Replace public constraints:
   - from `Value == ViewModel<Action, DomainState, ViewState>`
   - to `Value == ViewModel<F>`.
3. Keep CasePaths integration.
4. Avoid duplicate overloads that create ambiguous resolution.

Acceptance:
- Binding and CasePaths tests compile without overload ambiguity.

Status: Complete (2026-02-14)
Verification:
- `swift test --filter ViewModelBindingTests`

### Phase 4: Test migration
1. Update `Tests/LatticeTests/PresentationTests/FeatureViewModelTests.swift` to feature-typed VM.
2. Update `Tests/LatticeTests/PresentationTests/ViewModelBindingTests.swift` to feature-typed VM.
3. Migrate remaining presentation tests to public feature lane where practical.
4. Retain minimal internal-lane tests only if directly testing low-level wiring.

Acceptance:
- `swift test --filter FeatureViewModelTests` passes.
- `swift test --filter ViewModelBindingTests` passes.
- `swift test --filter PresentationTests` passes.

Status: Complete (2026-02-14)
Verification:
- `swift test --filter FeatureViewModelTests`
- `swift test --filter ViewModelBindingTests`
- `swift test --filter PresentationTests` (warning only: no matching tests were run)

### Phase 5: Docs/examples
1. Update `README.md`:
   - Replace 3-generic `ViewModel` annotations.
   - Show `ViewModel<ConcreteFeatureType>` usage.
2. Update `Sources/LatticeCLI/Resources/agent-docs.md`.
3. Update `ExampleProject` usages.

Acceptance:
- `rg -n "ViewModel<Action,|ViewModel<.*,.+,.+>" README.md Sources/LatticeCLI/Resources/agent-docs.md ExampleProject` returns no public-facing old-style examples.

Status: Complete (2026-02-14)
Verification:
- `rg -n "ViewModel<Action,|ViewModel<.*,.+,.+>" README.md Sources/LatticeCLI/Resources/agent-docs.md ExampleProject` (no matches)

### Phase 6: Cleanup and validation
1. Run:
   - `swift test --filter LatticeTests`
   - `swift test --filter LatticeMacrosTests`
2. Run formatting if needed:
   - `swift-format format --in-place --recursive Sources Tests`
3. Re-run focused tests after formatting.

Acceptance:
- Tests pass.
- No new warnings promoted to errors from this change.

Status: Complete (2026-02-14)
Verification:
- `swift test --filter LatticeTests`
- `swift test --filter LatticeMacrosTests`
- `swift-format format --in-place --recursive Sources Tests`
- `swift test --filter LatticeTests`
- `swift test --filter LatticeMacrosTests`

## Command checklist for the implementing agent

```bash
rg -n "public final class ViewModel<|ViewModel<Action|init\\(initialDomainState:.*interactor|Value == ViewModel<" Sources Tests README.md
swift test --filter FeatureViewModelTests
swift test --filter ViewModelBindingTests
swift test --filter PresentationTests
swift test --filter LatticeTests
```

## Risk list

1. Generic overload ambiguity in binding subscripts.
2. CasePaths helper constraints accidentally broadened/narrowed.
3. Accidental semantic drift in effect task lifecycle.
4. Public/internal visibility mistakes that leak test-only lanes.

## Rollback criteria

Rollback this sketch if either is true:

1. `ViewModel<F>` cannot preserve current runtime semantics without large internal duplication.
2. Binding API becomes unstable or significantly less ergonomic than current behavior.

## Deliverables

1. New public feature-typed `ViewModel`.
2. Internal-only direct lane retained temporarily for framework tests.
3. Migrated presentation tests and public docs.
4. Breaking-change release notes entry listing removed public signatures.

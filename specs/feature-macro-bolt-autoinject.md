# Sketch F: `@Feature` Macro With Bolt Auto-Resolution

## Goal
Provide a zero-boilerplate feature definition lane where consumers write only:

```swift
@Feature
struct CounterFeature {
    typealias Action = CounterEvent
    typealias DomainState = CounterDomainState
    typealias ViewState = CounterViewState

    let initialDomainState: DomainState
}
```

and the macro synthesizes `FeatureProtocol` conformance using `Bolt.inject()` for required members.

## Why
- Feature authors should not manually wire `AnyInteractor`, `AnyViewStateReducer`, or DI fields.
- Bolt already owns dependency graph composition through `DependencyModule` registrations.
- Consumer-facing feature definitions should remain lightweight and declarative.

## Scope

### In scope
- New attached macro: `@Feature` (no arguments).
- New attached marker macro: `@InjectionIgnored` for user-owned member overrides.
- Synthesis of `FeatureProtocol` members from typealiases/generic constraints and Bolt resolution.
- Macro tests for success/failure paths.
- Docs/examples for authoring features with `@Feature` + Bolt modules.

### Out of scope
- Changing Bolt public API.
- Reworking `ViewModel` runtime behavior.
- Introducing new DI containers or resolution semantics outside Bolt.

## Public API target

### Feature authoring

```swift
@Feature
struct CounterFeature {
    typealias Action = CounterEvent
    typealias DomainState = CounterDomainState
    typealias ViewState = CounterViewState

    let initialDomainState: DomainState
}
```

### Optional override via marker

```swift
@Feature
struct CounterFeature {
    typealias Action = CounterEvent
    typealias DomainState = CounterDomainState
    typealias ViewState = CounterViewState

    let initialDomainState: DomainState

    @InjectionIgnored
    var interactor: AnyInteractor<DomainState, Action> {
        CounterInteractor(logger: .test).eraseToAnyInteractor()
    }
}
```

### Expected synthesis (default path)

```swift
extension CounterFeature: FeatureProtocol {
    var interactor: AnyInteractor<DomainState, Action> {
        let value: some Interactor<DomainState, Action> & Sendable = Bolt.inject()
        return value.eraseToAnyInteractor()
    }

    var viewStateReducer: AnyViewStateReducer<DomainState, ViewState> {
        let value: some ViewStateReducer<DomainState, ViewState> & Sendable = Bolt.inject()
        return value.eraseToAnyReducer()
    }

    func makeInitialViewState(for domainState: DomainState) -> ViewState {
        let reducer: some ViewStateReducer<DomainState, ViewState> & Sendable = Bolt.inject()
        return reducer.initialViewState(for: domainState)
    }

    var areStatesEqual: (DomainState, DomainState) -> Bool {
        { $0 == $1 }
    }
}
```

## Type source rules

`@Feature` resolves `Action`, `DomainState`, and `ViewState` from either:

1. Struct-local typealiases (`typealias Action = ...`) or
2. Struct generic parameters/constraints.

At least one source must fully resolve all three types.

If ambiguous or missing, macro emits diagnostics with concrete fix-it guidance.

## `@InjectionIgnored` behavior

`@InjectionIgnored` may be attached only to members whose names match synthesized members:
- `interactor`
- `viewStateReducer`
- `makeInitialViewState`
- `areStatesEqual`

Rules:
- If marker is present, `@Feature` does not synthesize that member.
- If marker is present and compatible user member is missing or invalid, emit error.
- Marker on unrelated member name emits error.

## Bolt integration assumptions

- Interactor and reducer concrete types are registered in Bolt’s active container/module graph.
- Synthesis resolves both via `Bolt.inject()` (no generated `@Injected` fields).
- Dependency construction remains in `DependencyModule`:

```swift
final class CounterFeatureModule: DependencyModule {
    override var body: ModuleDefinition {
        Factory(CounterInteractor.self) { resolver in
            CounterInteractor(api: resolver.get(), logger: resolver.get())
        }

        Factory(CounterViewStateReducer.self) { _ in
            CounterViewStateReducer()
        }

        // other dependencies...
    }
}
```

## Diagnostics

### Required diagnostics
1. Missing type info for `Action`/`DomainState`/`ViewState`.
2. `DomainState` non-`Equatable` with no user-provided `areStatesEqual`.
3. `@InjectionIgnored` used on unsupported member.
4. User-defined ignored member has incompatible signature.
5. Synthesized member name conflicts with non-ignored user member.

## Agentic runbook (implementation)

### Phase 1: Macro API surfaces
1. Add `@Feature` macro declaration and plugin plumbing.
2. Add `@InjectionIgnored` marker macro declaration.
3. Expose both from `Lattice` public API.

Acceptance:
- Package compiles with both macro names exported.

### Phase 2: `@Feature` synthesis
1. Parse type source (typealias or generic constraints).
2. Synthesize `FeatureProtocol` conformance.
3. Generate Bolt-based defaults for required members.
4. Respect `@InjectionIgnored` exclusions.

Acceptance:
- Macro expansion snapshots show expected generated members.

### Phase 3: Diagnostics + edge cases
1. Add diagnostics for missing/ambiguous type info.
2. Add diagnostics for invalid ignored usage/signatures.
3. Add diagnostics for non-Equatable domain state missing comparator.

Acceptance:
- Negative macro tests assert expected diagnostics.

### Phase 4: Runtime integration tests
1. Add integration tests proving `ViewModel(feature:)` works with `@Feature`-authored types.
2. Configure Bolt modules in tests and verify interactor/reducer resolution.

Acceptance:
- Tests pass with module-backed Bolt resolution.

### Phase 5: Docs/examples
1. Update README feature authoring section with `@Feature` + Bolt module examples.
2. Update example project(s) to use `@Feature` where practical.
3. Document `@InjectionIgnored` override path.

Acceptance:
- Public docs demonstrate zero-arg `@Feature` and Bolt module wiring.

### Phase 6: Validation
1. Run:
   - `swift test --filter LatticeMacrosTests`
   - `swift test --filter LatticeTests`
2. Format changed files:
   - `swift-format format --in-place --recursive Sources Tests`
3. Re-run focused tests.

Acceptance:
- Tests pass.
- No macro expansion regressions.

## Command checklist for implementing agent

```bash
swift test --filter LatticeMacrosTests
swift test --filter LatticeTests
rg -n "@Feature|@InjectionIgnored|FeatureProtocol" Sources Tests README.md ExampleProject
```

## Risks

1. Inference ambiguity for generic-constrained feature definitions.
2. Overly strict ignored-member signature matching creating false negatives.
3. Runtime crash if Bolt container is missing interactor/reducer registrations.
4. Confusing diagnostics when both typealiases and generics are partially specified.

## Rollback criteria

Rollback this sketch if either is true:

1. Zero-arg `@Feature` cannot reliably infer required types without brittle heuristics.
2. `@InjectionIgnored` introduces unclear expansion behavior or significant maintainability cost.

## Deliverables

1. Zero-argument `@Feature` macro with Bolt-backed synthesis.
2. `@InjectionIgnored` marker for user-defined member overrides.
3. Macro and integration tests for success/failure paths.
4. Updated docs/examples centered on Bolt module composition.

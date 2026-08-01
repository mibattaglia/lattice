---
name: lattice-case-paths
description: Ergonomic enum access and generic algorithms for Lattice actions and feature state using CasePaths.
license: MIT
metadata:
  short-description: CasePaths ergonomics for Lattice enums.
---

# Lattice Case Paths

## Goal

Use CasePaths to make Lattice enums (Actions, feature-state enums, Effect-like enums) concise to read, write, and test. Prefer case key paths over verbose pattern matching when you need to probe, embed, or mutate associated values.

## When to use

- Action enums with associated values that you want to inspect or transform.
- Feature-state enums driving SwiftUI rendering or navigation.
- Tests that need to surgically modify an associated value without re-creating the whole enum.

## Quick start

1. Add the `swift-case-paths` package dependency (1.7.0+).
2. Add the `CasePaths` product to your target's dependencies.
3. `import CasePaths` where needed.
4. Apply `@CasePathable` to enums.

```swift
import CasePaths

@CasePathable
enum CounterAction {
    case increment
    case setCount(Int)
    case loadResponse(Result<Int, Error>)
}
```

## Lattice patterns

### Check the current case

```swift
if action.is(\.setCount) { ... }
```

### Extract associated values

```swift
let value = action[case: \.setCount]
```

### Embed values generically

```swift
let path: CaseKeyPath<CounterAction, Int> = \.setCount
let action = path(42)
```

### Mutate associated values in tests

```swift
var action = CounterAction.setCount(10)
action.modify(\.setCount) { $0 += 1 }
```

### Ergonomic access via dynamic member lookup

```swift
@CasePathable
@dynamicMemberLookup
enum LoadState {
    case idle
    case loading(progress: Double)
    case loaded(Int)
}

let state: LoadState = .loading(progress: 0.5)
let progress = state.loading
```

## SwiftUI + ViewModel bindings

When feature state is a `@FeatureState` `@CasePathable` enum, the Lattice `@Bindable` APIs can derive bindings to case payloads. This keeps SwiftUI code small and intent-driven.

```swift
@FeatureState
@CasePathable
enum ScreenState {
    case list(ListState)
    case detail(DetailState)
}

@Bindable var viewModel: ViewModel<ScreenState, Action>

let titleBinding = $viewModel.detail.title.sending(\.detailTitleChanged)
```

Use a fallback value when the case may be inactive:

```swift
let titleBinding = $viewModel.detail.title.sending(\.detailTitleChanged, default: "")
```

## Enum-case scoping

Case key paths also drive `ViewModel` scoping. `scope(state: KeyPath, action: CaseKeyPath)` embeds child actions through an action case, and when state itself is a `@FeatureState` `@CasePathable` enum, `scopeIfActive` projects onto the active case's payload via the generated case accessors:

```swift
if let list = viewModel.scopeIfActive(state: \.list, action: \.list) {
    ListView(model: list)
} else if let detail = viewModel.scopeIfActive(state: \.detail, action: \.detail) {
    DetailView(model: detail)
}
```

- `scopeIfActive(state:action:)` returns `nil` when the case is inactive — the branch condition and the scope in one call.
- The trapping `scope(state:action:)` variant is sugar for contexts that already established the case is active; it `fatalError`s otherwise.
- Same-case granularity comes from making the payload itself `@FeatureState`: a payload change recurses into the payload's own commit diff, so only the members that changed re-render.

## Asserting sent-back actions in tests

Most effects re-enter via `effectState.modify` and are asserted with `expect(changes:)`. When an
effect re-enters with `effectState.send`, assert it by case key path:

```swift
await model.receive(\.readyToClose) {
    $0.phase = .closed
}
```

## Gotchas

- Case paths are for enums only. Use regular key paths for structs.
- For enum feature state, prefer simple associated values and mark interactor-only payload members `@Domain`.
- `sending(_:)` on a case binding crashes if that case is inactive; use `sending(_:default:)` when the view may read outside the active case.

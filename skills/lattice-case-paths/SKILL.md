---
name: lattice-case-paths
description: Ergonomic enum access and generic algorithms for Lattice actions and view state using CasePaths.
license: MIT
metadata:
  short-description: CasePaths ergonomics for Lattice enums.
---

# Lattice Case Paths

## Goal

Use CasePaths to make Lattice enums (Actions, ViewState enums, Effect-like enums) concise to read, write, and test. Prefer case key paths over verbose pattern matching when you need to probe, embed, or mutate associated values.

## When to use

- Action enums with associated values that you want to inspect or transform.
- ViewState enums driving SwiftUI rendering or navigation.
- Tests that need to surgically modify an associated value without re-creating the whole enum.

## Quick start

1. Add the `swift-case-paths` package dependency (1.0.0+).
2. Add the `CasePaths` product to your target's dependencies.
3. `import CasePaths` where needed.
4. Apply `@CasePathable` to enums.

```swift
import CasePaths

@CasePathable
enum CounterAction: Sendable {
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
enum LoadState: Sendable {
    case idle
    case loading(progress: Double)
    case loaded(Int)
}

let state: LoadState = .loading(progress: 0.5)
let progress = state.loading
```

## SwiftUI + ViewModel bindings

When a ViewState is a `CasePathable` enum, the Lattice `@Bindable` APIs can derive bindings to case payloads. This keeps SwiftUI code small and intent-driven.

```swift
@ObservableState
@CasePathable
enum ScreenState: Sendable, Equatable {
    case list(ListState)
    case detail(DetailState)
}

@Bindable var viewModel: ViewModel<Feature<Action, DomainState, ScreenState>>

let titleBinding = $viewModel.detail.title.sending(\.detailTitleChanged)
```

Use a fallback value when the case may be inactive:

```swift
let titleBinding = $viewModel.detail.title.sending(\.detailTitleChanged, default: "")
```

## Gotchas

- Case paths are for enums only. Use regular key paths for structs.
- For view state, prefer enums with simple associated values and keep domain state in the interactor.

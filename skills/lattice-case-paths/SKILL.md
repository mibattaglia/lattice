---
name: lattice-case-paths
description: Ergonomic enum access and generic algorithms for Lattice actions and enum states using CasePaths.
license: MIT
metadata:
  short-description: CasePaths ergonomics for Lattice enums.
---

# Lattice Case Paths

## Goal

Use CasePaths to make Lattice enums (Actions, `@FeatureState` enum states and their `ViewState` mirrors, Effect-like enums) concise to read, write, and test. Prefer case key paths over verbose pattern matching when you need to probe, embed, or mutate associated values.

## When to use

- Action enums with associated values that you want to inspect or transform.
- Enum states driving SwiftUI rendering or navigation.
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
    case saved(id: Int)
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

When a feature's state is a `@CasePathable` `@FeatureState` enum, `@FeatureState` generates a `ViewState` mirror enum and carries `@CasePathable` onto it. The Lattice `@Bindable` APIs derive bindings to case payloads through that mirror, so `@Domain` members of a payload stay hidden. This keeps SwiftUI code small and intent-driven.

```swift
@CasePathable
@FeatureState
enum ScreenState: Equatable {
    case list(ListState)
    case detail(DetailState)
}

@Bindable var viewModel: ViewModel<Feature<ScreenAction, ScreenState>>

let titleBinding = $viewModel.detail.title.sending(\.detailTitleChanged)
```

`ListState` and `DetailState` are `@FeatureState` structs declared in another file (see "File layout" below).

Use a fallback value when the case may be inactive:

```swift
let titleBinding = $viewModel.detail.title.sending(\.detailTitleChanged, default: "")
```

## Enum-case scoping

Case key paths also drive `ViewModel` scoping. `scope(state: KeyPath, action: CaseKeyPath)` embeds child actions through an action case, and when the state itself is a `@CasePathable` `@FeatureState` enum, `scope(state: CaseKeyPath, action: CaseKeyPath)` projects onto the active case's payload. The state case path is rooted at the `ViewState` mirror:

```swift
switch viewModel.viewState {
case .list:
    ListView(model: viewModel.scope(state: \.list, action: \.list))
case .detail:
    DetailView(model: viewModel.scope(state: \.detail, action: \.detail))
}
```

- The trapping `scope` is for use inside a matched `switch` case; it `fatalError`s if the case is inactive.
- `scopeIfActive(state:action:)` returns `nil` instead, for conditional contexts.
- Only `@FeatureState` payloads can be scoped; a plain payload (`String`, a DTO) is read or bound through the mirror as is.
- In interactors, mutate the active payload in place, with CasePaths' `modify` on the state inside `interact` (`state.modify(\.detail) { ... }`) or `Interactors.When(state: \.detail, action: \.detail)`, so case scopes observe the change fine-grained; assigning a new case value is a wholesale replacement.

## Receiving sent actions in tests

An effect delivers its result with `effects.modify`, which a test asserts with `expect`. An action an effect sends, to start effects or to run interactor logic, is asserted with `receive`. When the action enum is `@CasePathable`, `TestModel.receive` and `TestViewModel.receive` can match by case key path instead of full-value equality:

```swift
await model.send(.saveTapped) { $0.isSaving = true }
await model.receive(\.saved) {  // any `.saved(id:)`: the payload is not compared
    $0.savedID = 7
    $0.isSaving = false
}
```

## File layout

A known Swift 6.4 compiler bug can crash the compiler (segfault in `TypeCheckPrimaryFileRequest`) when a source file holds a `@FeatureState` enum together with other macro-annotated declarations (other `@FeatureState` types, `@CasePathable` enums such as actions, `@Observable` classes, `@Interactor` types, …). Declare each `@FeatureState` enum, `@CasePathable` or not, in its own file with no other macro-annotated declaration; files whose `@FeatureState` types are all structs are not affected. This is a temporary workaround for the compiler bug, not a design rule.

## Gotchas

- Case paths are for enums only. Use regular key paths for structs.
- For enum states, make payload structs the feature owns `@FeatureState` and keep their domain-only members `@Domain`; keep primitive and foreign payloads plain.
- `@FeatureState` carries `@CasePathable` onto the `ViewState` mirror, but not `@dynamicMemberLookup`: read a payload off `viewModel.viewState` with `switch` or `[case: \.detail]`.
- `sending(_:)` on a case binding crashes if that case is inactive; use `sending(_:default:)` when the view may read outside the active case.

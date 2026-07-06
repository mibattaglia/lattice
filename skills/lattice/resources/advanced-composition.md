# Advanced Composition

## Compose interactors for larger features

Prefer composing interactors over embedding large branching logic in a single interactor. Keep each interactor focused on one domain state and action set, and use higher-order interactors to coordinate.

Use `when(state:action:child:)` or `Interactors.When` to scope child state/action pairs:
- `WritableKeyPath` for struct state
- `CaseKeyPath` for enum state

`InteractorBuilder` supports composition with `if`, `switch`, `for`, optionals, and arrays. Under the hood this yields `Merge`, `MergeMany`, or conditional wrappers.

## Scoped view composition

`ViewModel.scope(state:action:)` projects a parent view model onto a child slice of view state and a child action space, returning a `ScopedViewModel<ChildState, ChildAction>`. Child views take the scope instead of the parent's `ViewModel` type.

Overloads on `ViewModel`:

- `scope(state: KeyPath, action: CaseKeyPath)` — case-path sugar; requires `Action: CasePathable`.
- `scope(state: KeyPath, action: (ChildAction) -> Action)` — general closure embedding, no `CasePathable` requirement.
- `scope(state: KeyPath)` — read-only; the scope's action type is `Never`.

`ScopedViewModel` semantics:

- Stateless value type. It owns no state, effects, or lifecycle; recreate it on every render.
- Reads are live and fine-grained: `model.title` (or deeper, `model.badge.count`) walks the parent's `@ObservableState` getter chain, so the child re-renders only when the members it reads change.
- Reading the whole `model.viewState` value is coarse: it registers only the slice's identity (`_$id`) and re-renders only on wholesale slice replacement, not in-place leaf mutations.
- `sendViewEvent(_:)` embeds the child action into the parent action and returns the parent's `EventTask`.
- `binding(_:sending:)` derives a two-way binding: fine-grained getter, setter sends an embedded child action.
- Scopes compose: `ScopedViewModel.scope(state:action:)` projects a grandchild slice through the parent.
- Do not store scopes in `@State` or long-lived properties; a scope strongly retains its parent `ViewModel`.
- To hand off to a callback-based child view, wrap the send: `ChildView(action: { model.sendViewEvent($0) })`.

## Enum-case scoping

When view state (or a child slice) is a `CasePathable` enum, scope onto the active case's payload:

```swift
switch viewModel.viewState {
case .loading:
    LoadingView()
case .success:
    SuccessView(model: viewModel.scope(state: \.success, action: \.success))
}
```

- `scope(state: CaseKeyPath, action: CaseKeyPath)` traps with `fatalError` when the case is not active. Inside a matched `switch` case this cannot happen (body evaluation is synchronous on the main actor).
- `scopeIfActive(state:action:)` returns `nil` instead of trapping; use it when the case may legitimately be inactive.
- Reads are live: the scope re-extracts the payload from current view state on every access, so in-place payload mutations are observed fine-grained. If the case flips while the scope is still held, reads serve the payload captured at creation for at most one transitional render.
- A send can arrive after a case flip; interactors should drop actions that no longer apply to the current state.
- Reducers should mutate the active case's payload in place (`state.modify(\.success) { ... }`) for fine-grained updates; rebuilding the whole case value is a wholesale replacement and re-renders coarse observers.

## Sequential effects

Use `.append`, `appending(with:)`, or `.then(...)` when effect work must run in order.

- `.merge` runs child emissions concurrently.
- `.append` runs child emissions sequentially.
- Nested `.append` children are flattened and `.none` children are dropped, so higher-order composition stays predictable.

## Navigation-driven state

Keep navigation decisions in domain state and map to view state with a reducer. Prefer enums with associated values for destination state, and derive presentation data in view state.

## Async streams

Use `.observe` emissions when you need to consume a stream and map elements into actions. Keep stream setup inside the interactor to retain testability.
Use `.perform` for one-shot async work; it returns `Action?`, so `nil` is the supported no-op result for cancellation or intentionally silent work.

## Debounced effects

Apply `Emission.debounce(using:)` to debounce one-shot `.perform` emissions, or wrap a child interactor with `Interactors.Debounce(for:clock:child:)` when the feature should always debounce top-level perform work.

- `Interactors.Debounce` preserves immediate synchronous state updates.
- It only supports top-level `.perform`, `.none`, and `.action` child emissions.
- It is not a generic emission debouncer: top-level `.observe`, `.merge`, and `.append` trap.

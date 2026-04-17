# Interactors

`Interactor` is the core domain primitive in Lattice. It synchronously handles an action, mutates `DomainState`, and returns an `Emission<Action>` that describes any follow-up work.

Key source files:

- [Interactor.swift](../Sources/Lattice/Domain/Interactor.swift)
- [InteractorBuilder.swift](../Sources/Lattice/Domain/Interactor/InteractorBuilder.swift)
- [Interact.swift](../Sources/Lattice/Domain/Interactor/Interactors/Interact.swift)
- [When.swift](../Sources/Lattice/Domain/Interactor/Interactors/When.swift)
- [Merge.swift](../Sources/Lattice/Domain/Interactor/Interactors/Merge.swift)
- [MergeMany.swift](../Sources/Lattice/Domain/Interactor/Interactors/MergeMany.swift)
- [Debounce.swift](../Sources/Lattice/Domain/Interactor/Interactors/Debounce.swift)
- [Emission.swift](../Sources/Lattice/Domain/Emission.swift)

## Core Contract

The protocol shape is:

- `associatedtype DomainState: Sendable`
- `associatedtype Action: Sendable`
- `var body: Body`
- `func interact(state: inout DomainState, action: Action) -> Emission<Action>`

Interactors are synchronous at the mutation boundary:

- State mutation happens immediately.
- Async work is described by the returned `Emission<Action>`.

## The Interact Primitive

Most interactors are built with `Interact`.

`Interact` is a thin wrapper around a handler closure:

```swift
Interact { state, action in
    switch action {
    case .increment:
        state.count += 1
        return .none
    }
}
```

That closure is the primary place for domain rules.

## Builder Semantics

`InteractorBuilder` powers the `body` property.

It supports:

- Empty blocks via `EmptyInteractor`
- Single-child pass-through
- Multiple children via `Merge`
- Arrays and loops via `MergeMany`
- `if` and `if/else` via `Conditional`
- Optional branches
- Limited availability branches via type erasure

When multiple interactors are composed in one body, they all run against the same mutable state value in sequence.

## Composition Types

### Merge

`Merge<I0, I1>` runs two interactors sequentially on the same state and combines their emissions with `.merge([emission0, emission1])`.

Effect result:

- state mutation is sequential
- emitted work is concurrent

### MergeMany

`MergeMany` is the array and variadic equivalent of `Merge`.

It applies each interactor in order to the same state, collects their emissions, and returns `.merge(emissions)`.

### Conditional

`Conditional` is the result-builder form used for `if` and `if/else`.

Only the chosen branch runs.

### CollectInteractors

`CollectInteractors` is a wrapper around an interactor-builder closure. It is useful when an inline builder result needs to be stored or passed around as a single interactor value.

### When

`When` is the child-feature composition primitive.

It scopes a child interactor by:

- a writable key path for struct state, or
- a case path for enum state

And it extracts child actions from the parent action enum through a case path.

Behavior:

- Non-matching parent actions return `.none`.
- Matching child actions are forwarded into child state.
- Child emissions are mapped back into parent action space.
- Enum-state scoping embeds the updated child state back into the parent after the child interactor runs.

`when(state:action:child:)` is the ergonomic modifier that merges `When` with the parent interactor.

## Emission Forms

Interactors return `Emission<Action>`, which has six runtime forms:

- `.none`: no follow-up action
- `.action`: immediate follow-up action
- `.perform`: one-shot async work returning `Action?`
- `.observe`: async stream of actions
- `.merge`: concurrent composition of emissions
- `.append`: sequential composition of emissions

`.append` is normalized structurally when created:

- nested `.append` is flattened
- `.none` children are dropped
- empty results become `.none`
- one-child results unwrap to that child

## Debouncing

Lattice has two debounce layers.

### Emission-Level Debounce

`Emission.debounce(using:)` wraps `.perform` work with a debouncer.

Behavior:

- `.none` and `.action` pass through unchanged
- `.observe` passes through unchanged
- `.merge` and `.append` recurse through their children with the same debouncer

This is the most flexible debounce tool.

### Interactor-Level Debounce

`Interactors.Debounce` wraps a child interactor and delays only top-level `.perform` child emissions.

Important caveats:

- synchronous state mutation still happens immediately
- top-level `.none` and `.action` are allowed
- top-level `.observe`, `.merge`, and `.append` currently `fatalError`

Use this when the interactor shape is intentionally limited to one-shot effect work.

## Type Erasure And Sendability

`AnyInteractor<State, Action>` stores any `Sendable` interactor behind a uniform type.

There is also `UncheckedSendableInteractor` and `eraseToAnyInteractorUnchecked()` for cases where the interactor itself is not formally `Sendable` but the caller accepts responsibility for using it safely.

## Practical Guidance

- Put domain mutation in the interactor, not in `ViewModel`.
- Return emissions instead of starting tasks manually inside the view layer.
- Use `When` for child features instead of flattening all child logic into one large switch.
- Prefer `Emission.debounce(using:)` when you need recursive debounce behavior across composed emissions.

## Related Specs

- [ViewModel Event Loop And Emission Handling](./view-model-event-loop-and-emission-handling.md)
- [ViewStateReducer](./view-state-reducer.md)
- [Macros](./macros.md)

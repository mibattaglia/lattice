# Interactors

`Interactor` is the core domain primitive in Lattice. It handles an action synchronously: it mutates the feature's state and queues asynchronous work through the `Effects` handle it is given. In a feature, `State` is the feature's `@FeatureState` type, and the interactor, with the effects it performs, is the only code that changes it. How effects run, are cancelled and stay on the shell's isolation is described in [Effects And Isolation](./effects-and-isolation.md).

Key source files:

- [Interactor.swift](../Sources/Lattice/Domain/Interactor.swift): `Interactor`, `InteractorOf`, `AnyInteractor`
- [InteractorBuilder.swift](../Sources/Lattice/Domain/Interactor/InteractorBuilder.swift)
- [Interact.swift](../Sources/Lattice/Domain/Interactor/Interactors/Interact.swift)
- [Merge.swift](../Sources/Lattice/Domain/Interactor/Interactors/Merge.swift), [MergeMany.swift](../Sources/Lattice/Domain/Interactor/Interactors/MergeMany.swift), [ConditionalInteractor.swift](../Sources/Lattice/Domain/Interactor/Interactors/ConditionalInteractor.swift), [CollectInteractors.swift](../Sources/Lattice/Domain/Interactor/Interactors/CollectInteractors.swift), [EmptyInteractor.swift](../Sources/Lattice/Domain/Interactor/Interactors/EmptyInteractor.swift)
- [When.swift](../Sources/Lattice/Domain/Interactor/Interactors/When.swift)
- [Effects.swift](../Sources/Lattice/Domain/Effects.swift), [EffectID.swift](../Sources/Lattice/Domain/EffectID.swift), [Clock+Sleep.swift](../Sources/Lattice/Domain/Clock+Sleep.swift) (the `clock.sleep(for:)` overload effects call)
- Tests: [InteractorTests](../Tests/LatticeTests/DomainTests/InteractorTests) (`InteractorBuilderTests`, `Interactors+MergeTests`, `Interactors+MergeManyTests`, `Interactors+WhenTests`) and [EffectsTests](../Tests/LatticeTests/DomainTests/EffectsTests)

## Core Contract

```swift
public protocol Interactor<State, Action> {
    associatedtype State
    associatedtype Action
    associatedtype Body: Interactor
    @InteractorBuilder<State, Action> var body: Body { get }
    func interact(state: inout State, action: Action, effects: Effects<State, Action>)
}
```

- Nothing is required to be `Sendable`: not `State`, `Action`, the interactor, its dependencies or its effect closures.
- `interact` mutates the state synchronously and queues effects. It never suspends and never sends: `effects.send` during `interact` is reported and dropped, and the effects it performs start after it returns.
- The default `interact` forwards to `body`. A type that implements `interact` itself declares `var body: some InteractorOf<Self> { self }`; its `interact` takes precedence.
- `@Interactor<State, Action>` declares the conformance, the `State` and `Action` typealiases and the builder attribute on `body`; see [Macros](./macros.md#interactor). `InteractorOf<I>` is `Interactor<I.State, I.Action>`.
- `AnyInteractor<State, Action>` erases any interactor with the same `State` and `Action`, and `eraseToAnyInteractor()` builds one, with no constraint. `Feature(interactor:)` erases for you.
- `Action` should be an enum: auto-cancel keys on its case (see [Auto-Cancel](./effects-and-isolation.md#auto-cancel)).

## The Interact Primitive

Most interactors are built with `Interact`, a thin wrapper around a handler closure of type `(inout State, Action, Effects<State, Action>) -> Void` (`Interact.Handler`). It has two initializers, both `init(handler:)`, and the closure's parameter count picks one:

- `Interact { state, action, effects in … }` stores the handler as it is. A handler that performs effects uses this form.
- `Interact { state, action in … }` takes an `(inout State, Action) -> Void` handler and stores it wrapped in a `Handler` that ignores the `Effects` handle. A handler that performs no effects uses this form, as this counter does:

```swift
@Interactor<CounterState, CounterAction>
struct CounterInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
            case .decrement:
                state.count -= 1
            }
        }
    }
}
```

Either way, the handler returns nothing.

## Builder Semantics

`InteractorBuilder<State, Action>` powers `body`:

| Builder input | Result |
|---|---|
| empty block | `EmptyInteractor` |
| one child | the child itself |
| several children | `Interactors.Merge`, through partial blocks, whatever their types |
| a `for` loop | `Interactors.MergeMany`; `Interactors.MergeMany(interactors:)` also takes an array directly |
| `if`/`else` | `Interactors.Conditional` |
| `if` without `else` | erased to `AnyInteractor`, `EmptyInteractor` when false |
| `if #available` | erased to `AnyInteractor` |
| an expression typed `any Interactor<State, Action>` | erased to `AnyInteractor` |

```swift
@Interactor<CounterState, CounterAction>
struct AppCounterInteractor {
    let isLogging: Bool
    let extraCounters: Int

    var body: some InteractorOf<Self> {
        if isLogging {  // buildOptional: erased, `EmptyInteractor` when false
            LoggingInteractor()
        }
        for _ in 0..<extraCounters {  // buildArray: `Interactors.MergeMany`
            CounterInteractor()
        }
        CounterInteractor()  // consecutive children: `Interactors.Merge`, in order
    }
}
```

All children of one `body` run against the same mutable state, in order, with the same `Effects` handle. `body` is re-evaluated on every action, so a child built inside it is a new value each time; state and effect identity never live on an interactor instance (see [`@EffectID`](#effect-identity)).

## Composition Types

- **`Interactors.Merge<I0, I1>`** runs both interactors for every action, in order, with the same handle. Their state mutations are sequential and their effects start in that order. Two children that perform for the same action both run, and re-handling that action cancels both.
- **`Interactors.MergeMany<Element>`** is the array form of `Merge`: every element, in order.
- **`Interactors.Conditional<First, Second>`** is the enum behind `if`/`else`: only the chosen branch runs.
- **`Interactors.CollectInteractors<State, Action, Interactors>`** wraps an inline builder closure, so a builder result can be stored or passed around as one interactor value.
- **`EmptyInteractor<State, Action>`** ignores every action and performs nothing.

## When

`Interactors.When` scopes a child interactor to part of the parent's state and to a case of the parent's action:

```swift
@Interactor<ParentState, ParentAction>
struct ParentInteractor {
    var body: some InteractorOf<Self> {
        Interactors.When(state: \.counter, action: \.counter) {
            CounterInteractor()
        }
        Interact { state, action in
            switch action {
            case .reset:
                state.counter = CounterState()
            case .counter, .other:
                break
            }
        }
        .when(state: \.other, action: \.other) {  // `Merge(When, self)`: the child runs first
            CounterInteractor()
        }
    }
}

@Interactor<ScreenState, ScreenAction>
struct ScreenInteractor {
    var body: some InteractorOf<Self> {
        Interactors.When(state: \.loaded, action: \.loaded) {  // only while the state is `.loaded`
            LoadedInteractor()
        }
        Interact { state, action in
            if case .reload = action {
                state = .loading
            }
        }
    }
}
```

`ScreenState` is a `@CasePathable @FeatureState` enum with a `loaded(LoadedState)` case; like every `@FeatureState` enum it is declared alone in its file (see [FeatureState](./feature-state.md#limitations)).

- The state is a `WritableKeyPath` into a struct, or a `CaseKeyPath` into a `@CasePathable` enum. The action is always a `CaseKeyPath` into a `@CasePathable` action.
- A parent action that is not the child's case is ignored.
- Key-path form: the child mutates `state[keyPath:]` in place, so its member changes stay fine-grained.
- Case-path form: the child state is extracted, mutated and re-embedded into the parent case after the child returns. While the case is not active, the child's actions are ignored: nothing is scoped, and the child path is not visited, so none of the child's effects is cancelled.
- The child gets a scoped `Effects<ChildState, ChildAction>`. Its sends are embedded into parent actions, and its modifications are written back into the parent state (key-path assignment or case re-embedding), as one parent commit.
- The child handle's path adds the child action's tag, so `.child(.other)` does not cancel the effects of `.child(.start)`, and re-sending `.child(.start)` does. Its scope path adds the `When`'s key path or case key path, so two `When`s over the same child type keep independent `@EffectID` effects. See [Auto-Cancel](./effects-and-isolation.md#auto-cancel).
- A case-scoped child whose case went away changes nothing: its effects' sends and modifications are reported and dropped, and `effects.state` is reported and returns the last known value. If the case becomes active again, those effects read and write the new payload.
- `.when(state:action:child:)` is the modifier form. It returns `Interactors.Merge(When(…), self)`, so the child runs before the interactor it modifies.

## Writing Effects

These patterns come from the example packages under `ExampleProject/` and from the root tests, trimmed to the point each block shows. The mechanics behind each are in [Effects And Isolation](./effects-and-isolation.md).

### A result is a modification

An effect writes its result with `effects.modify`. There is no response case to send and handle:

```swift
case .refresh:
    state.isRefreshing = true
    effects.perform {
        defer { try? effects.modify { $0.isRefreshing = false } }  // also runs when cancelled
        let model = try await counterClient.fetch()
        try effects.modify {
            $0.count = model.count
            $0.lastUpdatedAt = model.updatedAt
        }
    }
```

- One `modify` for several members is one commit and one test entry.
- A cleanup flag is cleared in a `defer`, which runs when the effect is cancelled too.
- A run that is auto-cancelled or replaced runs its `defer` after its replacement has started, so a flag shared by consecutive runs can be cleared early: re-sending `.refresh` here sets `isRefreshing` to `false` once the cancelled run unwinds, while the new run is still refreshing.
- A failure that leaves this effect while it is live is reported as `Effect threw: <error>`. Catch the errors you expect and turn them into state; see [Thrown Errors](./effects-and-isolation.md#thrown-errors).

### Send only for the three jobs

`effects.send(_:)` is for what a modification cannot do: start new effects, run interactor logic that a parent, a `Merge` sibling or a `When` reacts to, or auto-cancel by action case. A response case that only carried a guard becomes that guard inside the `modify` body, as long as nothing else has to react to it:

```swift
case .loadTapped:
    effects.perform {
        try await clock.sleep(for: loadDuration)
        try effects.modify { state in
            guard case .loading = state else { return }  // was the `.loaded` case's guard
            state = .success(LoadSuccessState())
        }
    }
```

### Loops and streams

A timer is a `while true` loop around a throwing sleep, with one modification per tick:

```swift
case .startTicking:
    // Sending `.startTicking` again auto-cancels the running ticker.
    effects.perform {
        while true {  // ends when cancelled: the sleep throws
            try await clock.sleep(for: interval)
            try effects.modify(tick)
        }
    }
```

- Write `try await clock.sleep(for:)`, never `try?`. Both `ContinuousClock` and test clocks throw at once after a cancel, so a `try?` loop spins, committing ticks, until the model is invalidated.
- A `private func tick(_ state: inout State)` passed to `effects.modify(tick)` keeps the loop short.
- A stream is a `for await` inside one effect: `for await value in stream { try effects.modify { $0.apply(value) } }`.
- Several sequential steps are one effect doing them in order. Several concurrent ones are several `perform` calls, which interleave at their suspension points on the shell.

### Stale results

A cancelled effect's `modify` is still committed. When a newer action supersedes the result, check for cancellation right before the `modify`:

```swift
case .query(let query):
    state.query = query
    effects.perform {
        let results: [String]
        do {
            results = try await weatherService.searchWeather(query: query)
        } catch {
            results = []
        }
        // A newer edit cancelled this search while it ran: its results are stale. A
        // cancelled effect's modification is still committed, so check first.
        try Task.checkCancellation()
        try effects.modify { $0.results = results }
    }
```

- The check is required after `try?` or `catch`, which turn cancellation into a value, and whenever a superseded result differs from the current one.
- It is not needed when the only suspension is a sleep that throws on cancel and every run writes the same guarded value, like the `.loadTapped` load above: a late commit writes what the next load would, and the guard turns it into a no-op once the case changed.
- A `catch` that writes an error state checks for cancellation the same way, never with `error is CancellationError`.

### Debouncing

A debounce is a sleep at the top of the effect. The action changes the state at once, and re-handling its case auto-cancels the previous effect while it sleeps, so a burst of edits ends in one search, a full delay after the last edit (adapted from the Search example's `SearchQueryInteractor`):

```swift
case .query(let query):
    state.query = query  // the field changes at once
    guard !query.isEmpty else { return }  // starts no search, and still cancels the waiting one
    effects.perform {
        try await clock.sleep(for: debounceDuration)  // the next `.query` auto-cancels this sleep
        let results = (try? await weatherService.searchWeather(query: query)) ?? []
        try Task.checkCancellation()  // a newer edit cancelled this search while it ran
        try effects.modify { $0.results = results }
    }
```

- Coalescing is auto-cancel, per action case: another case leaves the sleeping effect alone, and a `.query` the guard ignores still cancels it (see [Auto-Cancel](./effects-and-isolation.md#auto-cancel)).
- A debounced effect that must survive an ignored action is identified: `perform(id:)` is replaced only by the next effect of its key (the Todos auto-sort, under [Effect identity](#effect-identity)).
- A cancel that lands after the sleep has returned, while the effect hops back to the shell, does not stop the effect (see [Cancellation is cooperative](./effects-and-isolation.md#cancellation-is-cooperative)). A debounced effect that delivers a result a newer action supersedes checks for cancellation before its `modify`.

### Clock injection

An interactor that waits takes its clock as a generic parameter, and a `ContinuousClock` convenience initializer keeps the app's call sites short:

```swift
@Interactor<TickerState, TickerAction>
struct TickerInteractor<C: Clock> {
    private let clock: C
    private let interval: C.Duration

    init(clock: C, interval: C.Duration) {
        self.clock = clock
        self.interval = interval
    }

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .startTicking:
                // Sending `.startTicking` again auto-cancels the running ticker.
                effects.perform {
                    while true {  // ends when cancelled: the sleep throws
                        try await clock.sleep(for: interval)
                        try effects.modify(tick)
                    }
                }
            }
        }
    }

    private func tick(_ state: inout TickerState) {
        state.ticks += 1
    }
}

extension TickerInteractor where C == ContinuousClock {
    init(interval: Duration = .seconds(1)) {
        self.init(clock: ContinuousClock(), interval: interval)
    }
}
```

Effects sleep with `try await clock.sleep(for:)`, in a file that imports Lattice. That spelling binds to Lattice's `nonisolated(nonsending)` overload, which starts on the shell's isolation: an `EffectClock` registers the sleep there, before `send` returns. Tests pass an `EffectClock` and move it with the test shell's `advance(_:by:)`; see [Testing Infrastructure](./testing-infrastructure.md#time).

### Effect identity

Use `@EffectID` with `perform(id:)` when an effect must survive its action being ignored (a repeat that performs it again replaces it), or must be cancelled from another case. An anonymous effect is cancelled by every send of its case, including one the interactor ignores. Adapted from the Todos example's `TodosInteractor`, with a `.stopSorting` case added to show `cancel`:

```swift
@Interactor<TodosState, TodosAction>
struct TodosInteractor<C: Clock> {
    /// Identified: replaced only by the next sort, never auto-cancelled, so a toggle the guards
    /// below ignore leaves the pending sort alone.
    @EffectID var autoSort
    let clock: C
    let autoSortDelay: C.Duration

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .setTodoCompletion(let id, let isComplete):
                guard let index = state.todos.firstIndex(where: { $0.id == id }) else { return }
                guard state.todos[index].isComplete != isComplete else { return }
                state.todos[index].isComplete = isComplete
                effects.perform(id: autoSort) {
                    try await clock.sleep(for: autoSortDelay)
                    try effects.modify { state in
                        state.todos.sort { !$0.isComplete && $1.isComplete }
                    }
                }
            case .stopSorting:
                effects.cancel(autoSort)  // another case: auto-cancel would not reach it
            }
        }
    }
}
```

When the view owns a long-lived effect, the simpler shape is no guard at all: re-sending the action replaces the running effect, and the view's `.task` cancels it when the view goes away (see [The Task `send` Returns](./effects-and-isolation.md#the-task-send-returns)).

### Dependencies

Dependencies are plain protocols, classes or closures, with no `Sendable`. In a module that does not enable `NonisolatedNonsendingByDefault`, their async methods are declared `nonisolated(nonsending)`, so that an effect calls them on the shell's isolation:

```swift
protocol WeatherService {
    nonisolated(nonsending) func searchWeather(query: String) async throws -> [String]
}
```

See [Concurrency Settings](./effects-and-isolation.md#concurrency-settings).

## Practical Guidance

- Put domain mutation in the interactor and its effects, not in the view model or the view.
- Deliver results with `effects.modify`; send actions only for the three jobs.
- Use `When` for child features instead of one large `switch`.
- Inject clocks into interactors that wait, and keep the `ContinuousClock` initializer for the app.
- Reach for `@EffectID` when an effect must survive an ignored action (a repeat that performs it again replaces it), or be cancelled from another case.

## Related Specs

- [Effects And Isolation](./effects-and-isolation.md)
- [FeatureState](./feature-state.md)
- [Macros](./macros.md)
- [Testing Infrastructure](./testing-infrastructure.md)

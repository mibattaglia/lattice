# Advanced Composition

## Compose interactors for larger features

Prefer composing interactors over embedding large branching logic in a single interactor. Keep each interactor focused on one state and action set, and use higher-order interactors to coordinate.

`InteractorBuilder`, the builder behind `body`, supports `if`, `switch` and `for`:

- Several children build `Interactors.Merge`. Each child runs in order against the same state with the same `Effects` handle, and their effects start in that order. Two children that perform for the same action both run, and re-handling that action cancels both.
- A `for` loop builds `Interactors.MergeMany`; `Interactors.MergeMany(interactors:)` takes an array directly. An array literal in `body` does not compile.
- `if`/`else` and `switch` build `Interactors.Conditional`. An `if` without `else` is erased to `AnyInteractor`, an `EmptyInteractor` when false.
- `eraseToAnyInteractor()` erases any interactor, with no constraint.

`body` is re-evaluated on every action, so a child built inside it is a new value each time. State and effect identity never live on an interactor instance.

Use `when(state:action:child:)` or `Interactors.When` to scope child state/action pairs:
- `WritableKeyPath` for struct state
- `CaseKeyPath` for a `@CasePathable` enum state

The action is always a `CaseKeyPath` into a `@CasePathable` action.

- The child gets an `Effects` handle of its own. Its sends are embedded into parent actions, and its `modify` writes back into the parent state as one parent commit.
- `.when(state:action:child:)` returns `Interactors.Merge(When(…), self)`, so the child runs before the interactor it modifies.
- Automatic cancellation follows the child case: `.child(.other)` leaves `.child(.start)`'s effects running, and re-sending `.child(.start)` cancels them.
- Two `When`s over the same child type keep independent `@EffectID` effects.
- With a case path, while the case is not active the child's actions are ignored and none of its effects is cancelled. A case-scoped child whose case went away changes nothing: its effects' sends and modifications are reported and dropped. If the case becomes active again, those effects read and write the new payload.

## Scoped view composition

`ViewModel.scope(state:action:)` projects a parent view model onto a child `@FeatureState` member and a child action space, returning a `ScopedViewModel<ChildState, ChildAction>`. Child views take the scope instead of the parent's `ViewModel` type. Key paths are rooted at the parent's `State.ViewState`, so `\.header` infers without annotation.

Overloads on `ViewModel` (and the same ones on `ScopedViewModel`):

- `scope(state: KeyPath, action: CaseKeyPath)` — case-path sugar; requires `Action: CasePathable`.
- `scope(state: KeyPath, action: CaseKeyPath)` to an optional child — returns `nil` while the child is absent.
- `scope(state: KeyPath, action: CaseKeyPath<Action, (ID, ChildAction)>)` to an `Array` or `IdentifiedArrayOf` of `Identifiable` children — one `Identifiable` scope per element, for `ForEach`. `IdentifiedArrayOf` finds elements in O(1), `Array` in O(n).
- `scope(state: KeyPath, action: (ChildAction) -> Action)` — general closure embedding, no `CasePathable` requirement.
- `scope(state: KeyPath)` — read-only; the scope's action type is `Never`.

`ScopedViewModel` semantics:

- Stateless value type. It owns no state, effects, or lifecycle; recreate it on every render.
- Reads are live and fine-grained: `model.title` (or deeper, `model.badge.count`) walks the parent's `@FeatureState` getter chain through `ChildState.ViewState`, so the child re-renders only when the members it reads change, and the child's `@Domain` members stay hidden.
- Reading the whole `model.viewState` value is coarse: it re-renders only when the child is replaced (or, for an enum child, changes case), not on in-place leaf mutations.
- `sendViewEvent(_:)` embeds the child action into the parent action and returns the parent's `Task<Void, Never>?` for the effects that send started.
- `binding(_:sending:)` derives a two-way binding: fine-grained getter, setter sends an embedded child action and discards the task.
- Scopes compose: `ScopedViewModel.scope(state:action:)` projects a grandchild through the parent.
- Do not store scopes in `@State` or long-lived properties; a scope strongly retains its parent `ViewModel`.
- To hand off to a callback-based child view, wrap the send: `ChildView(action: { model.sendViewEvent($0) })`.

## Enum-case scoping

When the state (or a child) is a `@CasePathable` `@FeatureState` enum, its generated `ViewState` is a `@CasePathable` mirror enum. Switch over it and scope onto the active case's payload:

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
- The case path is rooted at the mirror (`State.ViewState`) and the payload must be `@FeatureState`; a plain payload (`String`, a DTO) can be read and bound but not scoped.
- Reads are live: the scope re-extracts the payload from the current state on every access, so in-place payload mutations are observed fine-grained. If the case flips while the scope is still held, reads serve the payload captured at creation for at most one transitional render.
- A send can arrive after a case flip; interactors should drop actions that no longer apply to the current state (`Interactors.When` over a case path does).
- Interactors should mutate the active case's payload in place (`Interactors.When(state: \.success, action: \.success)` or CasePaths' `state.modify(\.success) { ... }`) for fine-grained updates; assigning a new case value is a wholesale replacement and re-renders every view that switches over the state.

## Sequential and concurrent effects

Several sequential steps are one effect doing them in order:

```swift
case .task:
    effects.perform {
        do {
            let profile = try await api.profile()
            try effects.modify { $0.profile = profile }
            let feed = try await api.feed(for: profile.id)
            try effects.modify { $0.feed = feed }
        } catch {
            try Task.checkCancellation()  // cancelled: write no error
            try effects.modify { $0.errorMessage = "\(error)" }
        }
    }
```

- Concurrent work is several `perform` calls in one `interact`. They start in order and interleave at their suspension points, all on the shell's isolation.
- An effect cannot call `perform`. To start new effects from an effect, send an action whose handling performs them: `try effects.send(.next)`. The send is processed at once, depth-first.
- A modification runs no interactor logic: a parent or `Merge` sibling cannot react to it. Send an action when one must.

## Navigation-driven state

Keep navigation decisions in the state, and expose presentation data through visible (often computed) members. Prefer enums with associated values for destination state, with `@FeatureState` payloads so destinations can be scoped.

## Async streams

A stream is a `for await` loop inside one effect, one modification per element:

```swift
case .task:
    effects.perform {
        for await status in monitor.statusUpdates {
            try effects.modify { $0.isOnline = status.isConnected }
        }
    }
```

- Re-sending `.task` cancels the running loop and starts a new one, so there is never more than one subscription.
- The view's `.task` forwards its cancellation to the task `sendViewEvent(_:)` returns, so the loop ends with the view. Deallocating the view model ends it too: `try effects.modify` then throws.

## Effect identity

An anonymous effect (performed without an `id`) is cancelled every time its action case is handled again, including by a send the interactor ignores. Give an effect an identity with `@EffectID` when it must survive its action being ignored (a repeat that performs it again replaces it), or must be cancelled from another case:

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

- The key is the declaration site, so every instance of the declaring type, including the new child instances `body` builds on every action, names the same effect. Nothing is stored in state.
- `perform(id:)` replaces the running effect of that key. `cancel(_:)` during `interact` is queued and runs in order when the queued effects start; from an effect it is immediate. `isRunning(_:)` is synchronous, and a cancel queued in the same `interact` is not reflected until then.
- For one effect per row, scope one declaration: `effects.perform(id: $download.scoped(row.id))` and `effects.cancel($download.scoped(row.id))`.
- Only a handle in the same scope can cancel or query a key; a parent and a view cannot. `isRunning` is not observable: a view reads a state flag the interactor sets and the effect clears in a `defer`.
- A guard on a running flag kept in state does not stop an ignored action from cancelling the running anonymous effect, and a `defer` that clears the flag does not fix it. Use `@EffectID`, or, when the view owns the effect, drop the guard so that re-sending the action replaces the running effect.
- A run that is replaced or auto-cancelled runs its `defer` after its replacement has started, so a flag shared by consecutive runs can be cleared while the newer run is still working.

## Debounced effects

Wrap a child with `Interactors.Debounce(for:clock:child:)` to delay every effect it performs:

```swift
@Interactor<SearchState, SearchAction>
struct DebouncedSearchInteractor<C: Clock> {
    let searchClient: SearchClient
    let clock: C
    let delay: C.Duration

    var body: some InteractorOf<Self> {
        Interactors.Debounce(for: delay, clock: clock) {  // built on every action: still debounces
            SearchInteractor(searchClient: searchClient)
        }
    }
}
```

- Actions go through the child at once, so the state changes immediately; each effect the child performs first sleeps for the duration on the clock, then runs.
- Coalescing is automatic cancellation: re-handling the action case cancels the previous effect while it sleeps, so a burst ends in one effect, a full delay after the last action.
- It holds no per-instance state, so it debounces the same stored in a property or built inside `body`.
- Effects performed with an `@EffectID` are delayed too; they are replaced per key instead of cancelled automatically.
- `child:` is a plain closure, not a builder: it returns one interactor. `Interactors.Debounce(for:child:)` uses `ContinuousClock`.
- A cancel that lands after the sleep returned, while the effect hops back to the shell, does not stop it. A debounced effect that delivers a result a newer action supersedes checks `try Task.checkCancellation()` before its `modify`.
- The other shape is a `try await clock.sleep(for:)` at the top of the effect itself.

## Timers and clocks

A timer is a `while true` loop around a throwing sleep, with one modification per tick. An interactor that waits takes its clock as a generic parameter, with a `ContinuousClock` initializer for the app:

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

- Write `try await clock.sleep(for:)`, never `try?`. Both `ContinuousClock` and test clocks throw at once after a cancel, so a `try?` loop spins, committing ticks, until the model is deallocated.
- Cancellation is cooperative: a cancel that lands while the tick hops back to the shell lets the loop commit at most one extra tick.
- Tests pass a test-local gate clock; see the `lattice-testing` skill.

## Errors and teardown

- A `CancellationError`, or any error thrown once the effect's task is cancelled, is not reported. The error of a live effect is reported as `Effect threw: …`.
- Every shell's `isolated deinit` cancels its effects. Afterwards `effects.send` and `effects.modify` throw `CancellationError` without reporting an issue.

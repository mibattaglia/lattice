# Advanced Composition

## Compose interactors for larger features

Prefer composing interactors over embedding large branching logic in a single interactor. Keep each interactor focused on one domain state and action set, and use higher-order interactors to coordinate.

Use `when(state:action:child:)` or `Interactors.When` to scope child state/action pairs:
- `WritableKeyPath` for struct state
- `CaseKeyPath` for enum state

`InteractorBuilder` supports composition with `if`, `switch`, `for`, optionals, and arrays. Under the hood this yields `Merge`, `MergeMany`, or conditional wrappers.

Child effects write through the state lens automatically: a child's `effectState.modify`
pulls back through the `when` key path or case path.

## Scoped view composition

`ViewModel.scope(state:action:)` projects a parent view model onto a child slice of the view projection and a child action space, returning a `ScopedViewModel<ChildState, ChildAction>`. Child views take the scope instead of the parent's `ViewModel` type.

Overloads on `ViewModel`:

- `scope(state: KeyPath, action: CaseKeyPath)` — case-path sugar; requires `Action: CasePathable`.
- `scope(state: KeyPath, action: (ChildAction) -> Action)` — general closure embedding, no `CasePathable` requirement.
- `scope(state: KeyPath)` — read-only; the scope's action type is `Never`.

`ScopedViewModel` semantics:

- Stateless value type. It owns no state, effects, or lifecycle; recreate it on every render.
- Reads are fine-grained: `model.title` (or deeper, `model.badge.count`) goes through the child's projection, so the child re-renders only when the members it reads change.
- `sendViewEvent(_:)` embeds the child action into the parent action and returns the parent's `EventTask`.
- `binding(_:sending:)` derives a two-way binding: projection-read getter, setter sends an embedded child action.
- Scopes compose: `ScopedViewModel.scope(state:action:)` projects a grandchild slice through the parent.
- Do not store scopes in `@State` or long-lived properties; a scope strongly retains its parent `ViewModel`.
- To hand off to a callback-based child view, wrap the send: `ChildView(action: { model.sendViewEvent($0) })`.

## Enum-case scoping

When state (or a child slice) is a `@FeatureState` `@CasePathable` enum, scope onto the active case's payload via the generated case accessors. `scopeIfActive(state:action:)` returns `nil` when the case is not active, which doubles as the branch condition:

```swift
if let success = viewModel.scopeIfActive(state: \.success, action: \.success) {
    SuccessView(model: success)
} else {
    LoadingView()
}
```

- The trapping `scope(state:action:)` variant is sugar for contexts that have already established the case is active; it `fatalError`s otherwise.
- Case-accessor projection reads (`if let detail = viewModel.detail { … }`) cover read-only branching without a scope.
- Reads are live: the scope re-extracts the payload from current state on every access, so in-place payload mutations are observed fine-grained. If the case flips while the scope is still held, reads serve the payload captured at creation for at most one transitional render.
- A send can arrive after a case flip; `When` drops it when the case is inactive, and interactors should still drop actions that no longer apply to the current state.
- Granularity inside a case comes from making the payload itself `@FeatureState`: a same-case payload change recurses into the payload's own commit diff.

## Sequential effects

Sequential work is sequential `await`s inside **one** `perform` closure:

```swift
effects.perform { [api] effectState in
    let profile = try await api.profile()
    try effectState.modify { $0.profile = profile }
    let feed = try await api.feed(profile.id)
    try effectState.modify { $0.feed = feed }
}
```

Concurrent work is multiple `perform` calls. For cross-effect ordering, await a named effect:
`try await someEffectID()` inside another effect waits for every task attached to that
`@EffectID` to finish.

## Navigation-driven state

Keep navigation decisions in domain state. Prefer enums with associated values for destination
state, and make each payload `@FeatureState` so views project it directly.

The drop contract: a child effect's `modify`/`send` after its `When` case departs is dropped
silently, and the child's tasks are cancelled at the departing commit. Design child effects so
this is safe — it is, by default, because re-entry is just a state write. Delete hand-rolled
nonce/generation guards; the runtime does what they approximated.

## Async streams

Streams are `for await` loops inside `perform`; there is no separate observe primitive:

```swift
case .task:
    effects.perform { [monitor] effectState in
        for await status in monitor.statusUpdates {
            try effectState.modify { $0.isOnline = status.isConnected }
        }
    }
```

- Re-dispatching the same action replaces the previous subscription (same `perform` call site).
- Leaving the enclosing `when` scope, or tearing down the `ViewModel`, cancels the loop.

## Debounced effects

There is no debounce API. The first `perform` at a call site during an update replaces that
call site's in-flight task, so a leading `clock.sleep` is the debounce window:

```swift
case .queryChanged(let query):
    state.query = query          // synchronous mutation, visible immediately
    effects.perform { [searchClient, clock] effectState in
        try await clock.sleep(for: .milliseconds(300))   // cancelled by the next keystroke
        let results = await searchClient.search(query)
        try effectState.modify { $0.results = results }
    }
```

Inject `any Clock<Duration>` and pass `TestClock` in tests. To coalesce across several call
sites, share one `@EffectID` between the `perform(id:)` calls — an id'd launch replaces the
previous task attached to the same id.

## Fine-grained observation notes

- Observation is per projected member, gated by the commit diff: a member's observers are
  poked only when its value (stored) or output (computed) actually changed at commit.
- Collections of `@FeatureState` elements (`IdentifiedArrayOf`) diff identity-keyed: only
  changed elements run their own commit, so one row's change fires only that row's members.
- Derived (computed) members evaluate at most once per commit, only while observed, and reads
  are served from a host-side cache.

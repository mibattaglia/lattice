# Advanced Composition

## Compose interactors for larger features

Prefer composing interactors over embedding large branching logic in a single interactor. Keep each interactor focused on one domain state and action set, and use higher-order interactors to coordinate.

Use `when(state:action:child:)` or `Interactors.When` to scope child state/action pairs:
- `WritableKeyPath` for struct state
- `CaseKeyPath` for enum state

`InteractorBuilder` supports composition with `if`, `switch`, `for`, optionals, and arrays. Under the hood this yields `Merge`, `MergeMany`, or conditional wrappers.

## Navigation-driven state

Keep navigation decisions in domain state and map to view state with a reducer. Prefer enums with associated values for destination state, and derive presentation data in view state.

## Async streams

Use `.observe` emissions when you need to consume a stream and map elements into actions. Keep stream setup inside the interactor to retain testability.

## Debounced effects

Apply `Emission.debounce(using:)` to debounce `.perform` emissions, or wrap a child interactor with `Interactors.Debounce(for:clock:child:)` for reusable effect-level debouncing.

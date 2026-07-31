# 04 — Interactor Protocol & Combinators

Workstream 4 of the Sendable-removal rework. Depends on plan 2 (core runtime: `GraphPath`,
task storage, commit funnel) and is co-designed with plan 3 (`Effects` handle). Lands in the
same PR train as 2 and 3 — the repo does not build between them.

## Overview

This plan rewrites the interactor layer around the pinned contract in `README.md`:

- `interact(state:action:effects:)` — synchronous, returns `Void`, no `Sendable` anywhere.
- Every combinator threads the `Effects` handle down the static composition tree, appending
  `GraphPath` components so the core can key effect tasks and cancellation buckets by
  structural position:
  - `When` pulls the handle back through its `(WritableKeyPath | CaseKeyPath, CaseKeyPath)`
    lenses and appends its state-path component.
  - `Merge` / `MergeMany` / builder blocks append positional indices.
  - `buildEither` (`Interactors.Conditional`) appends a branch tag.
  - `Interact` is a leaf: it hands the effects handle to the consumer closure unmodified.
- `AnyInteractor` loses all `Sendable` machinery; `UncheckedSendableInteractor` and friends
  are deleted because the problem they papered over no longer exists.
- `Emission` and the debounce stack are deleted (this plan owns the `Domain/` deletions and
  the two dead `Internal/` value types; plan 2 owns the rest of `Internal/`).

What deliberately does **not** change: `body` + `InteractorBuilder` composition (decision of
record: composition tree is static, `interact` stays), `InteractorOf`, the `when(state:action:child:)`
modifier shape, the `Interactors` namespace, and the file layout under
`Sources/Lattice/Domain/Interactor/`.

### Contract with plan 3 (pinned internal SPI)

The combinators need exactly two internal capabilities from `Effects`. Plan 3 implements them;
their signatures are pinned here so the parallel workstreams cannot drift. Any change requires
updating both plans.

```swift
extension Effects {
    /// Returns a handle whose GraphPath is `self.path + component`. Same domain; perform/modify/
    /// send/state all route to the same core with the extended path.
    internal func appending(_ component: GraphPath.Component) -> Effects<DomainState, Action>

    /// Pullback for `When` (struct-state lens). The child handle's `modify` writes through the
    /// key path; `send` embeds through the action case path; `state` reads through the key path.
    /// Path is `self.path + component`.
    internal func scoped<ChildState, ChildAction>(
        state: WritableKeyPath<DomainState, ChildState>,
        action: AnyCasePath<Action, ChildAction>,
        component: GraphPath.Component
    ) -> Effects<ChildState, ChildAction>

    /// Pullback for `When` (enum-state lens). If the parent's enum has left the child's case
    /// when a child effect calls `modify`/`send`, the mutation is dropped silently and the
    /// path-prefix task bucket is cancelled.
    internal func scoped<ChildState, ChildAction>(
        state: AnyCasePath<DomainState, ChildState>,
        action: AnyCasePath<Action, ChildAction>,
        component: GraphPath.Component
    ) -> Effects<ChildState, ChildAction>
}
```

`GraphPath.Component` is the pinned `case keyPath(AnyKeyPath), id(AnyHashable)`. `When` uses
`.keyPath(_:)` for **both** lens variants — a `CaseKeyPath<Root, Value>` *is* a
`KeyPath<Case<Root>, Case<Value>>`, so it hashes and compares as an `AnyKeyPath` with stable
in-process identity. Positional and branch components use `.id(_:)`.

### Path derivation (worked example)

```swift
var body: some InteractorOf<Self> {
    Interactors.When(state: \.counter, action: \.counter) {   // buildPartialBlock pair
        CounterInteractor()
    }
    Interact { state, action, effects in ... }
}
```

`buildPartialBlock(accumulated:next:)` produces `Merge(When, Interact)`:

| Node | GraphPath (relative to feature root) |
|---|---|
| `When` wrapper | `[.id(0)]` |
| `CounterInteractor` leaves | `[.id(0), .keyPath(\.counter)]` (+ whatever the child body appends) |
| `Interact` leaf | `[.id(1)]` |

Three siblings nest as `Merge(Merge(A, B), C)` → `A = [.id(0), .id(0)]`, `B = [.id(0), .id(1)]`,
`C = [.id(1)]`. Uniqueness and per-process stability are what the task-storage keying needs;
flat indices are not required. When a parent's enum leaves a child's case, the core cancels by
path *prefix* `[..., .keyPath(childLens)]`, which covers the child's entire subtree regardless
of nesting shape.

---

## File-by-file

### 1. `Sources/Lattice/Domain/Interactor.swift` — protocol + `AnyInteractor`

Signature-level diff against the current protocol:

```diff
 public protocol Interactor<DomainState, Action> {
-    associatedtype DomainState: Sendable
-    associatedtype Action: Sendable
+    associatedtype DomainState
+    associatedtype Action
     associatedtype Body: Interactor

     @InteractorBuilder<DomainState, Action>
     var body: Body { get }

-    func interact(state: inout DomainState, action: Action) -> Emission<Action>
+    func interact(
+        state: inout DomainState,
+        action: Action,
+        effects: Effects<DomainState, Action>
+    )
 }
```

`Body` and `body` survive: the pinned README keeps `InteractorBuilder`/`When`/`Merge`
composition, and `body` is how the builder attaches to the protocol. The default-`interact`
extension forwards the effects handle unchanged (composition nodes, not `body` itself, append
path components).

`AnyInteractor` diff:

```diff
-public struct AnyInteractor<State: Sendable, Action: Sendable>: Interactor, Sendable {
-    private let interactFunc: @Sendable (inout State, Action) -> Emission<Action>
+public struct AnyInteractor<State, Action>: Interactor {
+    private let interactFunc: (inout State, Action, Effects<State, Action>) -> Void

-    public init<I: Interactor & Sendable>(_ base: I) where I.DomainState == State, I.Action == Action {
+    public init<I: Interactor>(_ base: I) where I.DomainState == State, I.Action == Action {
```

`eraseToAnyInteractor()` loses its `Self: Sendable` gate. `UncheckedSendableInteractor`,
`uncheckedSendable()`, and `eraseToAnyInteractorUnchecked()` are deleted outright (see table).

Full replacement file:

```swift
import Foundation

/// A type that processes **actions** by mutating **domain state** and launching effects.
///
/// An `Interactor` is the core unit of a feature's business logic. It processes actions
/// synchronously in the host's isolation domain, mutating state in place and launching
/// imperative async effects through the ``Effects`` handle.
///
/// ## Declaring an Interactor
///
/// Use the `@Interactor` macro for a concise declaration:
///
/// ```swift
/// @Interactor<CounterState, CounterAction>
/// struct CounterInteractor {
///     var body: some InteractorOf<Self> {
///         Interact { state, action in
///             switch action {
///             case .increment:
///                 state.count += 1
///             case .decrement:
///                 state.count -= 1
///             }
///         }
///     }
/// }
/// ```
///
/// ## Effects
///
/// Async work is launched during the synchronous update phase and re-enters by mutating
/// state directly:
///
/// ```swift
/// Interact { state, action, effects in
///     switch action {
///     case .refresh:
///         state.isLoading = true
///         effects.perform { [api] effectState in
///             let items = try await api.fetchItems()
///             try effectState.modify { state in
///                 state.isLoading = false
///                 state.items = items
///             }
///         }
///     }
/// }
/// ```
///
/// ## Custom Implementation
///
/// For advanced scenarios, implement `interact(state:action:effects:)` directly. Custom
/// implementations take precedence over `body`.
public protocol Interactor<DomainState, Action> {
    /// The type of state this interactor mutates.
    associatedtype DomainState
    /// The type of actions this interactor processes.
    associatedtype Action
    /// The concrete type returned by the result-builder `body` property.
    associatedtype Body: Interactor

    /// A declarative description of this interactor constructed with ``InteractorBuilder``.
    ///
    /// `body` must be a pure, stable description: it is evaluated as part of the static
    /// composition tree and must return the same structure every time.
    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    /// Processes an action by mutating state and, optionally, launching effects.
    ///
    /// Runs synchronously in the host's isolation domain during the update phase.
    ///
    /// - Parameters:
    ///   - state: The current state, passed as `inout` for mutation.
    ///   - action: The action to process.
    ///   - effects: The handle for launching async effects. Only ``Effects/perform(id:_:)``
    ///     is legal during this call; `modify`/`send` are effect-phase APIs.
    func interact(
        state: inout DomainState,
        action: Action,
        effects: Effects<DomainState, Action>
    )
}

extension Interactor where Body.DomainState == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
    }
}

extension Interactor where Body: Interactor<DomainState, Action> {
    /// The default implementation forwards to the `body` interactor.
    public func interact(
        state: inout DomainState,
        action: Action,
        effects: Effects<DomainState, Action>
    ) {
        body.interact(state: &state, action: action, effects: effects)
    }
}

/// A convenience alias that exposes the `DomainState` and `Action` associated types of an
/// ``Interactor``.
public typealias InteractorOf<I: Interactor> = Interactor<I.DomainState, I.Action>

/// A type-erased wrapper around any ``Interactor``.
///
/// Use `AnyInteractor` when you need to store interactors with different concrete types
/// but the same `State` and `Action` types:
///
/// ```swift
/// let interactor: AnyInteractor<MyState, MyAction> = CounterInteractor()
///     .eraseToAnyInteractor()
/// ```
public struct AnyInteractor<State, Action>: Interactor {
    private let interactFunc: (inout State, Action, Effects<State, Action>) -> Void

    public init<I: Interactor>(_ base: I) where I.DomainState == State, I.Action == Action {
        self.interactFunc = { state, action, effects in
            base.interact(state: &state, action: action, effects: effects)
        }
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {
        interactFunc(&state, action, effects)
    }
}

extension Interactor {
    /// Erases this interactor to ``AnyInteractor``.
    public func eraseToAnyInteractor() -> AnyInteractor<DomainState, Action> {
        AnyInteractor(self)
    }
}
```

Path note: `AnyInteractor` is structurally transparent — it forwards the handle unmodified, so
erasure never perturbs `GraphPath`s.

### 2. `Sources/Lattice/Domain/Interactor/Interactors/Interact.swift` — leaf

```diff
-public struct Interact<State: Sendable, Action: Sendable>: Interactor, @unchecked Sendable {
-    public typealias Handler = (inout State, Action) -> Emission<Action>
+public struct Interact<State, Action>: Interactor {
+    public typealias Handler = (inout State, Action, Effects<State, Action>) -> Void
```

Full replacement file:

```swift
import Foundation

/// The core primitive for handling actions within an ``Interactor``.
///
/// `Interact` is the leaf of the composition tree: it hands the ``Effects`` handle it
/// receives directly to the consumer closure, appending no structural path component.
///
/// ## Basic Usage
///
/// ```swift
/// @Interactor<CounterState, CounterAction>
/// struct CounterInteractor {
///     var body: some InteractorOf<Self> {
///         Interact { state, action in
///             switch action {
///             case .increment: state.count += 1
///             case .decrement: state.count -= 1
///             }
///         }
///     }
/// }
/// ```
///
/// ## Async Work
///
/// ```swift
/// Interact { state, action, effects in
///     switch action {
///     case .fetchData:
///         state.isLoading = true
///         effects.perform { [api] effectState in
///             let data = try await api.fetch()
///             try effectState.modify { state in
///                 state.isLoading = false
///                 state.data = data
///             }
///         }
///     }
/// }
/// ```
///
/// A second `effects.perform` triggered from the *same* call site replaces the previous
/// in-flight task automatically (per-call-site auto-replacement), which is how debouncing and
/// search-as-you-type are expressed — see ``Effects/perform(id:_:)``.
public struct Interact<State, Action>: Interactor {
    /// The type of the handler closure that processes actions.
    public typealias Handler = (inout State, Action, Effects<State, Action>) -> Void

    private let handler: Handler

    /// Creates an `Interact` primitive with the given handler.
    ///
    /// - Parameter handler: A closure that mutates state and may launch effects.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Creates an `Interact` primitive for pure state mutation.
    ///
    /// Convenience for interactors that never launch effects; the effects handle is
    /// dropped so call sites don't need a `, _ in` placeholder.
    public init(handler: @escaping (inout State, Action) -> Void) {
        self.handler = { state, action, _ in handler(&state, action) }
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {
        handler(&state, action, effects)
    }
}
```

The two `init(handler:)` overloads disambiguate on closure arity; existing `Interact { state,
action in ... }` bodies that only mutated state and returned `.none` migrate by deleting the
`return .none` line.

### 3. `Sources/Lattice/Domain/Interactor/Interactors/Merge.swift`

```diff
-    public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor, @unchecked Sendable
-    where I0.DomainState: Sendable, I0.Action: Sendable {
+    public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor {
```

Full replacement file:

```swift
extension Interactors {
    /// Combines two interactors into one, forwarding each action to both.
    ///
    /// `Merge` is used internally by ``InteractorBuilder`` when multiple interactors
    /// are listed sequentially in the `body`:
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     LoggingInteractor()
    ///     CounterInteractor()  // Merged with LoggingInteractor
    /// }
    /// ```
    ///
    /// Each action is processed by both interactors sequentially. Each child receives an
    /// effects handle with a positional `GraphPath` component appended (`.id(0)` / `.id(1)`),
    /// so effects launched by the two children never collide in the core's task storage.
    ///
    /// - Note: For merging more than two interactors, see ``MergeMany``.
    public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor {
        private let i0: I0
        private let i1: I1

        /// Creates a merged interactor from two child interactors.
        ///
        /// - Parameters:
        ///   - i0: The first interactor.
        ///   - i1: The second interactor.
        public init(_ i0: I0, _ i1: I1) {
            self.i0 = i0
            self.i1 = i1
        }

        public var body: some Interactor<I0.DomainState, I0.Action> { self }

        public func interact(
            state: inout I0.DomainState,
            action: I0.Action,
            effects: Effects<I0.DomainState, I0.Action>
        ) {
            i0.interact(state: &state, action: action, effects: effects.appending(.id(0)))
            i1.interact(state: &state, action: action, effects: effects.appending(.id(1)))
        }
    }
}
```

### 4. `Sources/Lattice/Domain/Interactor/Interactors/MergeMany.swift`

```diff
-    public struct MergeMany<Element: Interactor>: Interactor, @unchecked Sendable
-    where Element.DomainState: Sendable, Element.Action: Sendable {
+    public struct MergeMany<Element: Interactor>: Interactor {
```

Full replacement file:

```swift
extension Interactors {
    /// Combines an array of interactors into one, forwarding each action to all.
    ///
    /// `MergeMany` is used internally by ``InteractorBuilder`` when interactors are
    /// provided via array syntax or variadic parameters. Each child receives an effects
    /// handle with its positional index appended as a `GraphPath` component (`.id(i)`).
    ///
    /// - Important: Path identity is positional. `for`-loops that build interactors from
    ///   dynamic collections must produce a stable order; reordering the collection at
    ///   runtime is unsupported (the composition tree is static).
    ///
    /// - Note: For merging exactly two interactors, see ``Merge``.
    public struct MergeMany<Element: Interactor>: Interactor {
        private let interactors: [Element]

        /// Creates a merged interactor from an array of child interactors.
        ///
        /// - Parameter interactors: The interactors to merge.
        public init(interactors: [Element]) {
            self.interactors = interactors
        }

        public var body: some Interactor<Element.DomainState, Element.Action> { self }

        public func interact(
            state: inout Element.DomainState,
            action: Element.Action,
            effects: Effects<Element.DomainState, Element.Action>
        ) {
            for (index, interactor) in interactors.enumerated() {
                interactor.interact(state: &state, action: action, effects: effects.appending(.id(index)))
            }
        }
    }
}
```

### 5. `Sources/Lattice/Domain/Interactor/Interactors/When.swift`

The load-bearing rewrite. Structural changes:

```diff
-        public struct When<ParentState: Sendable, ParentAction: Sendable, Child: Interactor & Sendable>:
-            Interactor, Sendable
-        where Child.DomainState: Sendable, Child.Action: Sendable {
+        public struct When<ParentState, ParentAction, Child: Interactor>: Interactor {
...
-            enum StatePath: @unchecked Sendable {
+            enum StatePath {
                 case keyPath(WritableKeyPath<ParentState, Child.DomainState>)
                 case casePath(AnyCasePath<ParentState, Child.DomainState>)
             }
+            private let pathComponent: GraphPath.Component
...
-            public func interact(state: inout ParentState, action: ParentAction) -> Emission<ParentAction> {
-                guard let childAction = toChildAction.extract(from: action) else {
-                    return .none
-                }
-                switch toChildState {
-                case .keyPath(let keyPath):
-                    let childEmission = child.interact(state: &state[keyPath: keyPath], action: childAction)
-                    return childEmission.map { [toChildAction] in toChildAction.embed($0) }
-                case .casePath(let casePath):
-                    guard var childState = casePath.extract(from: state) else { return .none }
-                    defer { state = casePath.embed(childState) }
-                    let childEmission = child.interact(state: &childState, action: childAction)
-                    return childEmission.map { [toChildAction] in toChildAction.embed($0) }
-                }
-            }
+            public func interact(
+                state: inout ParentState,
+                action: ParentAction,
+                effects: Effects<ParentState, ParentAction>
+            ) { ... }  // pulls the handle back through the lenses; see full source
```

Note what disappeared: `childEmission.map(toChildAction.embed)` — the action-re-mapping that
existed only because effects re-entered as actions. Re-entry is now `modify` through the state
lens; the action case path is still threaded into the scoped handle so the *optional*
`effectState.send` re-entry embeds correctly.

Full replacement file:

```swift
import Foundation

#if canImport(CasePaths)
    import CasePaths
#endif

#if canImport(CasePaths)
    extension Interactors {
        /// Embeds a child interactor in a parent domain.
        ///
        /// `When` allows you to scope a parent domain to a child domain, running a child
        /// interactor on that subset. This enables modular feature composition by breaking
        /// large features into smaller, testable units.
        ///
        /// ## Usage with KeyPath (struct state)
        ///
        /// ```swift
        /// var body: some InteractorOf<Self> {
        ///     Interactors.When(state: \.counter, action: \.counter) {
        ///         CounterInteractor()
        ///     }
        ///     Interact { state, action in
        ///         // Additional parent logic
        ///     }
        /// }
        /// ```
        ///
        /// ## Usage with CaseKeyPath (enum state)
        ///
        /// ```swift
        /// var body: some InteractorOf<Self> {
        ///     Interactors.When(state: \.loaded, action: \.loaded) {
        ///         LoadedInteractor()
        ///     }
        /// }
        /// ```
        ///
        /// ## How It Works
        ///
        /// 1. Actions matching `toChildAction` are extracted and forwarded to the child.
        /// 2. The child receives an ``Effects`` handle pulled back through the state and
        ///    action lenses, with this node's state path appended as a `GraphPath` component.
        ///    Child effects mutate parent state through the lens via `modify`.
        /// 3. For case-path state, child state is embedded back into parent state after the
        ///    child's synchronous update.
        /// 4. Non-matching actions pass through untouched.
        ///
        /// ## Dismissal semantics
        ///
        /// If the parent's enum has left the child's case (or the scoped optional is `nil`)
        /// by the time a child effect calls `modify`, the mutation is **dropped silently**
        /// and the child subtree's in-flight tasks are cancelled, so effects that outlive
        /// a dismissed child never write stale state back into the parent.
        public struct When<ParentState, ParentAction, Child: Interactor>: Interactor {
            public typealias DomainState = ParentState
            public typealias Action = ParentAction

            enum StatePath {
                case keyPath(WritableKeyPath<ParentState, Child.DomainState>)
                case casePath(AnyCasePath<ParentState, Child.DomainState>)
            }

            private let toChildState: StatePath
            private let toChildAction: AnyCasePath<ParentAction, Child.Action>
            private let pathComponent: GraphPath.Component
            private let child: Child

            init(
                toChildState: StatePath,
                toChildAction: AnyCasePath<ParentAction, Child.Action>,
                pathComponent: GraphPath.Component,
                child: Child
            ) {
                self.toChildState = toChildState
                self.toChildAction = toChildAction
                self.pathComponent = pathComponent
                self.child = child
            }

            /// Creates a scoped interactor for struct state using a writable key path.
            ///
            /// - Parameters:
            ///   - toChildState: A writable key path from parent state to child state.
            ///   - toChildAction: A case key path from parent action to child actions.
            ///   - child: A closure that returns the child interactor.
            public init<ChildState, ChildAction>(
                state toChildState: WritableKeyPath<ParentState, ChildState>,
                action toChildAction: CaseKeyPath<ParentAction, ChildAction>,
                @InteractorBuilder<ChildState, ChildAction> child: () -> Child
            ) where ChildState == Child.DomainState, ChildAction == Child.Action {
                self.init(
                    toChildState: .keyPath(toChildState),
                    toChildAction: AnyCasePath(toChildAction),
                    pathComponent: .keyPath(toChildState),
                    child: child()
                )
            }

            /// Creates a scoped interactor for enum state using a case key path.
            ///
            /// - Parameters:
            ///   - toChildState: A case key path from parent state to child state.
            ///   - toChildAction: A case key path from parent action to child actions.
            ///   - child: A closure that returns the child interactor.
            public init<ChildState, ChildAction>(
                state toChildState: CaseKeyPath<ParentState, ChildState>,
                action toChildAction: CaseKeyPath<ParentAction, ChildAction>,
                @InteractorBuilder<ChildState, ChildAction> child: () -> Child
            ) where ChildState == Child.DomainState, ChildAction == Child.Action {
                self.init(
                    toChildState: .casePath(AnyCasePath(toChildState)),
                    toChildAction: AnyCasePath(toChildAction),
                    // CaseKeyPath is a KeyPath; its identity is the structural component.
                    pathComponent: .keyPath(toChildState),
                    child: child()
                )
            }

            public var body: some Interactor<ParentState, ParentAction> { self }

            public func interact(
                state: inout ParentState,
                action: ParentAction,
                effects: Effects<ParentState, ParentAction>
            ) {
                guard let childAction = toChildAction.extract(from: action) else {
                    return
                }

                switch toChildState {
                case .keyPath(let keyPath):
                    let childEffects = effects.scoped(
                        state: keyPath,
                        action: toChildAction,
                        component: pathComponent
                    )
                    child.interact(
                        state: &state[keyPath: keyPath],
                        action: childAction,
                        effects: childEffects
                    )

                case .casePath(let casePath):
                    guard var childState = casePath.extract(from: state) else {
                        return
                    }
                    let childEffects = effects.scoped(
                        state: casePath,
                        action: toChildAction,
                        component: pathComponent
                    )
                    child.interact(state: &childState, action: childAction, effects: childEffects)
                    state = casePath.embed(childState)
                }
            }
        }
    }
#endif

#if canImport(CasePaths)
    /// Convenience alias for `Interactors.When`.
    public typealias WhenInteractor<ParentState, ParentAction, Child: Interactor> =
        Interactors.When<ParentState, ParentAction, Child>

    // MARK: - Interactor Modifier

    extension Interactor {
        /// Scopes a child interactor to a subset of state and actions.
        ///
        /// ```swift
        /// var body: some InteractorOf<Self> {
        ///     Interact { state, action in
        ///         // Parent logic
        ///     }
        ///     .when(state: \.child, action: \.child) {
        ///         ChildInteractor()
        ///     }
        /// }
        /// ```
        ///
        /// - Parameters:
        ///   - toChildState: A writable key path from parent state to child state.
        ///   - toChildAction: A case key path from parent action to child actions.
        ///   - child: A closure that returns the child interactor.
        /// - Returns: A combined interactor that handles both parent and child domains.
        public func when<ChildState, ChildAction, Child: Interactor>(
            state toChildState: WritableKeyPath<DomainState, ChildState>,
            action toChildAction: CaseKeyPath<Action, ChildAction>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
        ) -> Interactors.Merge<Interactors.When<DomainState, Action, Child>, Self>
        where Child.DomainState == ChildState, Child.Action == ChildAction {
            Interactors.Merge(
                Interactors.When(state: toChildState, action: toChildAction, child: child),
                self
            )
        }

        /// Scopes a child interactor to a subset of state and actions (enum state variant).
        ///
        /// - Parameters:
        ///   - toChildState: A case key path from parent state to child state.
        ///   - toChildAction: A case key path from parent action to child actions.
        ///   - child: A closure that returns the child interactor.
        /// - Returns: A combined interactor that handles both parent and child domains.
        public func when<ChildState, ChildAction, Child: Interactor>(
            state toChildState: CaseKeyPath<DomainState, ChildState>,
            action toChildAction: CaseKeyPath<Action, ChildAction>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
        ) -> Interactors.Merge<Interactors.When<DomainState, Action, Child>, Self>
        where Child.DomainState == ChildState, Child.Action == ChildAction {
            Interactors.Merge(
                Interactors.When(state: toChildState, action: toChildAction, child: child),
                self
            )
        }
    }
#endif
```

Semantics worth spelling out:

- **Synchronous case-absence** (case-path lens, `extract` fails during `interact`): the child
  never runs — unchanged behavior from today. Task cancellation for the *transition* into
  absence is the core's job (transition detection in the commit funnel, plan 2), not `When`'s.
- **Asynchronous case-absence** (child effect calls `modify` after dismissal): handled inside
  the scoped handle (plan 3) — drop + cancel by path prefix `effects.path + pathComponent`.
- The child's synchronous mutations still land in the same update-phase `inout` state, so the
  single commit funnel (transition detection → projection diff) sees parent and
  child mutations as one commit. `When` needs no commit hooks of its own.

### 6. `Sources/Lattice/Domain/Interactor/Interactors/ConditionalInteractor.swift`

```diff
-    public enum Conditional<First: Interactor, Second: Interactor<First.DomainState, First.Action>>: Interactor,
-        @unchecked Sendable
-    where First.DomainState: Sendable, First.Action: Sendable {
+    public enum Conditional<First: Interactor, Second: Interactor<First.DomainState, First.Action>>: Interactor {
```

Full replacement file:

```swift
import Foundation

/// Branch identity for `Interactors.Conditional` GraphPath components.
enum ConditionalBranch: Hashable {
    case first
    case second
}

extension Interactors {
    /// An interactor that conditionally delegates to one of two child interactors.
    ///
    /// `Conditional` is used internally by `InteractorBuilder` for `if-else` statements:
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     if useFeatureA {
    ///         FeatureAInteractor()
    ///     } else {
    ///         FeatureBInteractor()
    ///     }
    /// }
    /// ```
    ///
    /// Each branch appends a branch-tag `GraphPath` component, so the two branches occupy
    /// disjoint task-storage buckets. The composition tree is static: the branch taken is
    /// fixed when `body` is first evaluated and must not change for the lifetime of the host.
    public enum Conditional<First: Interactor, Second: Interactor<First.DomainState, First.Action>>: Interactor {
        case first(First)
        case second(Second)

        public var body: some Interactor<First.DomainState, First.Action> { self }

        public func interact(
            state: inout First.DomainState,
            action: First.Action,
            effects: Effects<First.DomainState, First.Action>
        ) {
            switch self {
            case .first(let first):
                first.interact(
                    state: &state,
                    action: action,
                    effects: effects.appending(.id(ConditionalBranch.first))
                )
            case .second(let second):
                second.interact(
                    state: &state,
                    action: action,
                    effects: effects.appending(.id(ConditionalBranch.second))
                )
            }
        }
    }
}
```

### 7. `Sources/Lattice/Domain/Interactor/Interactors/EmptyInteractor.swift`

Full replacement file:

```swift
import Foundation

/// An interactor that does nothing — ignores all actions.
///
/// Use this for conditional interactor composition where sometimes no processing is needed.
///
/// ## Usage
///
/// ```swift
/// var body: some InteractorOf<Self> {
///     if enableLogging {
///         LoggingInteractor()
///     } else {
///         EmptyInteractor()
///     }
/// }
/// ```
public struct EmptyInteractor<State, Action>: Interactor {
    public typealias DomainState = State
    public typealias Action = Action

    /// Creates an empty interactor.
    public init() {}

    public var body: some InteractorOf<Self> { self }

    public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {}
}
```

### 8. `Sources/Lattice/Domain/Interactor/Interactors/CollectInteractors.swift`

Structurally transparent wrapper — appends no component; the builder result it wraps appends
its own positional indices. Full replacement file:

```swift
import Foundation

extension Interactors {
    /// An interactor that wraps an interactor builder result.
    ///
    /// `CollectInteractors` enables creating interactors inline using the builder syntax.
    /// It is structurally transparent: it forwards the effects handle unmodified.
    public struct CollectInteractors<State, Action, Interactors: Interactor>: Interactor
    where State == Interactors.DomainState, Action == Interactors.Action {
        private let interactors: Interactors

        public init(@InteractorBuilder<State, Action> _ build: () -> Interactors) {
            self.interactors = build()
        }

        public var body: some Interactor<State, Action> { self }

        public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {
            interactors.interact(state: &state, action: action, effects: effects)
        }
    }
}
```

### 9. `Sources/Lattice/Domain/Interactor/InteractorBuilder.swift`

```diff
 @resultBuilder
-public enum InteractorBuilder<State: Sendable, Action: Sendable> {
+public enum InteractorBuilder<State, Action> {
...
     @_disfavoredOverload
     public static func buildExpression(
         _ expression: any Interactor<State, Action>
     ) -> AnyInteractor<State, Action> {
-        let erased: AnyInteractor<State, Action> = expression.eraseToAnyInteractorUnchecked()
-        return erased
+        expression.eraseToAnyInteractor()
     }
```

Full replacement file:

```swift
import Foundation

/// A *result builder* that composes multiple ``Interactor`` values into a single
/// interactor.
///
/// The builder powers the `body` property of every ``Interactor`` implementation.  You can use
/// regular control-flow (`if`, `switch`, `for`), optional and array literals to declaratively
/// combine smaller interactors into more complex ones.
///
/// Composition is structural: sibling positions, `if/else` branches, and `When` lenses each
/// append a `GraphPath` component, giving every effect-launching leaf a stable structural
/// identity for task storage and cancellation.
///
/// ```swift
/// struct Feature: Interactor {
///   var body: some Interactor<State, Action> {
///     LoggingInteractor()
///     CounterInteractor()
///     if isPremium {
///       AnalyticsInteractor()
///     }
///   }
/// }
/// ```
@resultBuilder
public enum InteractorBuilder<State, Action> {
    /// Builds an interactor from an array literal `[...]` or a `for` loop.
    public static func buildArray(
        _ interactors: [some Interactor<State, Action>]
    ) -> some Interactor<State, Action> {
        Interactors.MergeMany(interactors: interactors)
    }

    /// Builds an empty block.
    public static func buildBlock() -> some Interactor<State, Action> {
        EmptyInteractor()
    }

    /// Pass-through overload for a single child.
    public static func buildBlock<I: Interactor<State, Action>>(_ interactor: I) -> I {
        interactor
    }

    /// Variadic overload for `I...` syntax.
    public static func buildBlock<I: Interactor<State, Action>>(_ interactors: I...)
        -> Interactors.MergeMany<I>
    {
        Interactors.MergeMany(interactors: interactors)
    }

    /// Builds the first branch of an `if`/`else` statement.
    public static func buildEither<I0: Interactor<State, Action>, I1: Interactor<State, Action>>(
        first interactor: I0
    ) -> Interactors.Conditional<I0, I1> {
        .first(interactor)
    }

    /// Builds the second branch of an `if`/`else` statement.
    public static func buildEither<I0: Interactor<State, Action>, I1: Interactor<State, Action>>(
        second interactor: I1
    ) -> Interactors.Conditional<I0, I1> {
        .second(interactor)
    }

    /// Accepts an expression that is already an ``Interactor``.
    public static func buildExpression<I: Interactor<State, Action>>(_ expression: I) -> I {
        expression
    }

    /// Accepts an expression typed as `any Interactor` and erases it.
    @_disfavoredOverload
    public static func buildExpression(
        _ expression: any Interactor<State, Action>
    ) -> AnyInteractor<State, Action> {
        expression.eraseToAnyInteractor()
    }

    public static func buildFinalResult<I: Interactor<State, Action>>(_ interactor: I) -> I {
        interactor
    }

    public static func buildLimitedAvailability(
        _ wrapped: some Interactor<State, Action>
    ) -> AnyInteractor<State, Action> {
        wrapped.eraseToAnyInteractor()
    }

    public static func buildOptional(_ wrapped: (any Interactor<State, Action>)?) -> AnyInteractor<
        State, Action
    > {
        wrapped?.eraseToAnyInteractor() ?? EmptyInteractor<State, Action>().eraseToAnyInteractor()
    }

    public static func buildPartialBlock<I: Interactor<State, Action>>(first: I) -> I {
        first
    }

    public static func buildPartialBlock<
        I0: Interactor<State, Action>, I1: Interactor<State, Action>
    >(
        accumulated: I0, next: I1
    ) -> Interactors.Merge<I0, I1> {
        Interactors.Merge(accumulated, next)
    }
}
```

(`first Interactor:` / `second Interactor:` internal parameter names were lowercased in
passing — capitalized locals shadowing the protocol name; zero API impact since the labels
are `first:`/`second:`.)

Existential `expression.eraseToAnyInteractor()` works via implicit existential opening (the
result binds only primary associated types, which are fixed to `State`/`Action`).

### 10. `Sources/Lattice/Domain/Interactor/Interactors/Interactors.swift`

Unchanged (`public enum Interactors {}`).

---

## Deletions & replacement idioms

Files deleted by this plan:

- `Sources/Lattice/Domain/Emission.swift` (incl. internal `DebounceToken`,
  `EmissionExecutionOptions`, `DebounceExecutionOptions`)
- `Sources/Lattice/Domain/Emission+Debounce.swift`
- `Sources/Lattice/Domain/Interactor/Interactors/Debounce.swift`
- `Sources/Lattice/Domain/DynamicState.swift`
- `Sources/Lattice/Internal/Send.swift`
- `Sources/Lattice/Internal/UncheckedSendable.swift`
- `Sources/Lattice/Internal/Debouncer.swift`, `Sources/Lattice/Internal/DebounceResult.swift`
  (orphaned by the debounce deletions; execution-side deletions such as `EmissionExecution`,
  `ApplyAction`, and the registries are owned by plan 2)

| Deleted API | Was | Replacement idiom |
|---|---|---|
| `Emission.none` | "no follow-up" sentinel | Nothing — `interact` returns `Void`; delete the `return .none`. |
| `Emission.action(_:)` | synchronous self-send | Mutate state directly, or factor the shared logic into a plain function both cases call. (`try effectState.send(_:)` exists for *effect-phase* re-entry only; it is never the update-phase idiom.) |
| `Emission.perform(work:)` | async work → follow-up action | `effects.perform { effectState in … try effectState.modify { state in … } }` — the effect mutates state directly; no round-trip action, no `.dataLoaded` case. |
| `Emission.observe(stream:)` | stream → action per element | `effects.perform { effectState in for await x in stream { effectState.latest = x } }` — no separate observe primitive. |
| `Emission.merge(_:)` | combine child emissions | Call `effects.perform` multiple times; combinators just call children sequentially. |
| `Emission.append(_:)` / `.then` | sequential effects | Sequential `await`s inside one `effects.perform` closure. |
| `Emission.map(_:)` | action re-mapping in `When` | Gone — `Effects.scoped` pulls `modify`/`send` back through the lenses instead. |
| `Emission.debounce(using:)` (`Emission+Debounce.swift`) | debounced perform | Per-call-site auto-replacement: a new `effects.perform` at the same `(GraphPath, location)` replaces the in-flight task; prepend `try await clock.sleep(for: duration)` inside the closure for the quiet period. |
| `Interactors.Debounce` / `DebounceInteractor` | wrapper debouncing child emissions | Same idiom as above, written at the leaf that launches the effect. Cross-call-site coalescing: a shared `@EffectID`. First-class debounce API is deferred (decision of record). |
| `Debouncer` (actor) | timing/coalescing engine | Deleted; auto-replacement + `clock.sleep` covers it. |
| `DebounceResult` (`.executed`/`.superseded`) | preserved superseded-vs-nil distinction | Deleted; "superseded" is now literally a cancelled `Task` — no value-level encoding needed. |
| `Send<State>` (dead code) | prototyped state-mutating yield | `try effectState.modify(_:)` |
| `DynamicState<State>` (dead code) | prototyped async state read | `effectState.state` |
| `UncheckedSendable<T>` (unused) | cross-isolation smuggling | None needed; nothing crosses an isolation boundary. |
| `UncheckedSendableInteractor`, `.uncheckedSendable()`, `.eraseToAnyInteractorUnchecked()` | escape hatch for non-Sendable interactors | `AnyInteractor(_:)` / `.eraseToAnyInteractor()` — the Sendable requirement they escaped no longer exists. |

---

## Before/after consumer examples

### 1. An interactor with a perform effect

Before (action ping-pong — two cases, one just to receive the result):

```swift
Interact { state, action in
    switch action {
    case .fetchData:
        state.isLoading = true
        return .perform { [api] in
            let data = try? await api.fetch()
            return .dataLoaded(data)
        }
    case .dataLoaded(let data):
        state.isLoading = false
        state.data = data
        return .none
    }
}
```

After (one case; the effect re-enters via `modify`; `.dataLoaded` is deleted from the Action
enum):

```swift
Interact { state, action, effects in
    switch action {
    case .fetchData:
        state.isLoading = true
        effects.perform { [api] effectState in
            let data = try await api.fetch()
            try effectState.modify { state in
                state.isLoading = false
                state.data = data
            }
        }
    }
}
```

### 2. A `When` composition

Before:

```swift
@Interactor<AppState, AppAction>
struct AppInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interactors.When(state: \.counter, action: \.counter) {
            CounterInteractor()
        }
        Interact { state, action in
            switch action {
            case .reset:
                state = AppState()
                return .none
            case .counter:
                return .none
            }
        }
    }
}
```

After (body shape identical; `Sendable` gone, `return .none` gone; the child's effects now
mutate `AppState.counter` through the lens automatically):

```swift
@Interactor<AppState, AppAction>
struct AppInteractor {
    var body: some InteractorOf<Self> {
        Interactors.When(state: \.counter, action: \.counter) {
            CounterInteractor()
        }
        Interact { state, action in
            switch action {
            case .reset:
                state = AppState()
            case .counter:
                break
            }
        }
    }
}
```

### 3. A merge

Before:

```swift
var body: some InteractorOf<Self> {
    LoggingInteractor()      // returns .none for everything
    CounterInteractor()
    if isPremium {
        AnalyticsInteractor()
    }
}
```

After — source-identical; each sibling now transparently gets a positionally path-extended
effects handle, and the `if` branch gets a branch tag:

```swift
var body: some InteractorOf<Self> {
    LoggingInteractor()      // effects path: [.id(0), .id(0)]
    CounterInteractor()      // effects path: [.id(0), .id(1)]
    if isPremium {
        AnalyticsInteractor()  // effects path: [.id(1), .id(ConditionalBranch.first)]
    }
}
```

---

## Test plan

New/rewritten suites (final harness style is plan 7's snapshot-diff `TestViewModel`; the
structural tests below use a lightweight `@testable` path recorder and do not depend on it):

1. **Path derivation** (`InteractorGraphPathTests`, new): a `PathRecordingInteractor` leaf that
   captures `effects` handle paths (via an internal `Effects.graphPath` accessor, `@testable`).
   Assert:
   - `Merge(A, B)` → `[.id(0)]` / `[.id(1)]`; nested `Merge(Merge(A,B),C)` → `[.id(0),.id(0)]`,
     `[.id(0),.id(1)]`, `[.id(1)]`.
   - `MergeMany([A,B,C])` → `.id(0)/.id(1)/.id(2)`.
   - `Conditional.first/.second` → distinct branch-tag components for the same builder position.
   - `When(state: \.counter, …)` child path ends in `.keyPath(\.counter)`; case-path variant
     ends in `.keyPath(\ParentState.Cases.loaded)`; two `When`s over different lenses at the
     same position produce distinct paths.
   - `AnyInteractor`/`CollectInteractors`/`buildOptional` wrappers are transparent (path
     unchanged through erasure).
2. **`When` routing** (rewrite of existing `WhenInteractorTests`): child action extracted and
   forwarded; non-matching parent action is a no-op; case-path variant with absent case does
   not invoke the child; child synchronous mutations embed back into parent state; child
   `effects.perform` → `modify` lands in the parent's scoped slice. (The
   dismissed-mid-request drop/cancel contract is tested in plans 3/7 where the core hooks
   live; this plan's tests only assert `When` builds the scoped handle with the right lenses
   and component.)
3. **Builder shapes compile** (rewrite of `InteractorBuilderTests`): single child, two/three
   siblings, array literal, `for` loop, `if` without `else`, `if/else`, `#available` block,
   `any Interactor<S, A>` expression. Plus runtime assertion that every shape forwards actions
   to all live children.
4. **Non-Sendable erasure** (new, the headline): an interactor holding a non-Sendable class
   reference (e.g. a mutable `final class` service) composes in a body, erases via
   `eraseToAnyInteractor()`, and runs — compiles with zero `@unchecked` anywhere.
5. **`Interact` overloads**: 2-arg and 3-arg trailing closures both resolve; 2-arg variant
   never observes an effects handle.
6. **Debounce idiom regression** (replaces `Interactors+DebounceTests` /
   `EmissionDebounceTests`): with `TestClock`, rapid re-sends of the same action at one
   location run only the last effect (auto-replacement), state mutates immediately each send.
   Lives here as the replacement-idiom proof even though the mechanism is plan 2/3 code.

Deleted test files (no shims, per decision of record): `Interactors+DebounceTests`, all
`Emission*` tests, and any test using `eraseToAnyInteractorUnchecked()` (currently
`EventTaskTests`, `FeatureViewModelTests`, `ViewModelBindingTests`, `ViewModelTests` — those
call sites flip to `eraseToAnyInteractor()`; broader rewrites belong to plans 6/7).

Commands: `swift build`, `swift test --filter LatticeTests` (macro tests unaffected — the
macro plugin references neither `Emission` nor `interact`, confirmed by grep; binary refresh
is plan 8).

## Acceptance gates

1. `swift build` succeeds at the head of the 2+3+4 PR train (plans 2–4 merge together; this
   plan alone does not build).
2. Grep gates over `Sources/Lattice/Domain/`:
   - zero occurrences of `Sendable` (including `@unchecked Sendable`);
   - zero occurrences of `Emission`, `Debounce`, `DynamicState`, `UncheckedSendable`;
   - the eight deleted files listed above are gone.
3. `swift test --filter LatticeTests` green, including the new `InteractorGraphPathTests` and
   the rewritten `WhenInteractorTests`/`InteractorBuilderTests`.
4. Path contract holds: every combinator's component matches the pinned README rules (When →
   lens keypath, builder/Merge → positional `.id`, buildEither → branch tag, Interact/erasure
   wrappers → none). Verified by test suite 1.
5. The non-Sendable erasure test (suite 4) compiles without any `@unchecked` or
   `nonisolated(unsafe)` in test code.
6. `Effects` SPI used here (`appending(_:)`, both `scoped(state:action:component:)` overloads)
   matches plan 3's implementation exactly.

## Risks

- **Plan 3/4 drift** (top risk): the internal `Effects` SPI is pinned in both plans; if plan 3
  changes a signature, this plan's `When`/`Merge` code must be re-synced before the train
  merges. Mitigation: gate 6 + shared review of both plan docs.
- **`body` purity is now load-bearing**: the default `interact` re-evaluates `body` per action
  (unchanged from today), but path identity assumes the same structure every evaluation. An
  impure `body` (branch flips at runtime) silently strands tasks under the old branch tag —
  no remount machinery exists by design. Mitigated by documentation on `body` and
  `Conditional`; plan 2/6 may additionally capture the root interactor once at host init.
- **Positional path fragility across code edits**: inserting a sibling shifts `.id(n)`
  components. Paths are only ever compared within one process lifetime (task storage), never
  persisted, so this is benign — but tests must not hard-code paths of production features,
  only of fixtures.
- **`CaseKeyPath`-as-`AnyKeyPath` identity**: relies on key-path literal identity being stable
  in-process (it is; same guarantee TCA26's `_GraphPath` uses). Two distinct literals for the
  same case compare equal — fine.
- **Overload resolution of the two `Interact.init(handler:)`s**: arity disambiguates trailing
  closures; a pathological fully-inferred closure could be ambiguous. If it bites in practice,
  rename the convenience label — no design change.
- **Consumer break is total and intentional**: every `interact` body, every custom
  `Interactor` conformance, and every `Emission` return migrates by hand. Migration guide is
  plan 9; the before/after section above is its seed.
- **Downstream compile fallout inside the repo**: `Feature`, `ViewModel`, `ScopedViewModel`,
  and `Testing/` all reference the old signature and `Sendable` gates — owned by plans 6/7,
  which is why this plan only builds as part of the train.

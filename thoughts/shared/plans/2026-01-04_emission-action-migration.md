# Emission<Action> Migration - System Design

Last Updated: 2026-01-04

## Executive Summary

This design proposes migrating UnoArchitecture from `Emission<State>` (effects emit full state) to `Emission<Action>` (effects emit actions). This shift fundamentally changes how effects communicate with the system: instead of computing new state directly in async contexts, effects send actions back through the same processing pipeline as user interactions. This eliminates the need for `DynamicState` in effects, trivializes scoping (action mapping vs state adaptation), and aligns with proven architectures like TCA while preserving Uno's unique synchronous interactor pattern.

**Key Architectural Shift**: Effects become "action producers" rather than "state producers." The interactor remains the single source of truth for all state changes. This makes effects simpler (no state reading), testing easier (just assert actions), and composition trivial (action mapping with `.map`).

> **Terminology Note**: In Uno, "Interactor" is equivalent to TCA's "Reducer" - both process actions and mutate state. Uno reserves "Reducer" for `ViewStateReducer`, which transforms DomainState → ViewState.

## Context & Requirements

### Current Architecture

**Emission<State> Model**:
```swift
// Effects emit FULL STATE
return .perform { state, send in
    let data = try await api.fetch()
    var currentState = await state.current  // Read current state
    currentState.data = data
    currentState.isLoading = false
    await send(currentState)  // Send new state
}
```

**Key Characteristics**:
- Effects have `DynamicState<State>` - can read current state at any time
- Effects have `Send<State>` - can emit full state updates
- State mutations can happen both in interactor (synchronously) AND in effects (asynchronously)
- Scoping requires complex state adaptation for higher-order interactors

### Problem Statement

**Complexity in Effects**:
1. **State Reading**: Effects need `DynamicState` to read current state before emitting
2. **State Construction**: Effects must construct full state objects, duplicating interactor logic
3. **Race Conditions**: Multiple effects can read stale state and clobber each other's changes
4. **Testing**: Must assert on full state objects from effects, not just actions

**Scoping Complexity**:
```swift
// Current: State adaptation in When
case .keyPath(let kp):
    var childState = state[keyPath: kp]
    let childEmission = child.interact(state: &childState, action: childAction)
    state[keyPath: kp] = childState
    return childEmission.scope(to: kp)  // Complex state transformation

// childEmission.scope() must transform DynamicState and Send callbacks!
```

**Comparison to TCA**:
TCA uses `Effect<Action>` successfully:
- Effects are simpler (just emit actions)
- Scoping is trivial (`.map { .child($0) }`)
- All state changes go through reducer
- Testing is easier (assert actions, not state)

### Why Emission<Action> is Better

**Simpler Effects**:
```swift
// Effects emit ACTIONS
return .perform {
    let data = try await api.fetch()
    return .fetchCompleted(data)  // Just an action!
}
```

No `DynamicState`, no state reading, no state construction. Just emit actions.

**Trivial Scoping**:
```swift
// New: Action mapping in When
case .keyPath(let kp):
    var childState = state[keyPath: kp]
    let childEmission = child.interact(state: &childState, action: childAction)
    state[keyPath: kp] = childState
    return childEmission.map { .child($0) }  // Simple action wrapping!
```

**Single Source of Truth**:
All state changes flow through the interactor. Effects can't accidentally clobber state.

**Better Testing**:
```swift
// Test effects by asserting actions
await harness.send(.fetch)
#expect(harness.receivedActions == [.fetchStarted, .fetchCompleted(data)])
```

### Requirements

1. **Effects Emit Actions**: Change `Emission<State>` to `Emission<Action>`
2. **Remove DynamicState**: Effects no longer need to read state
3. **Remove Send<State>**: Effects return actions, not state
4. **Trivial Scoping**: Add `.map` to transform child actions to parent actions
5. **Interactor Remains Sync**: `interact(state:action:) -> Emission<Action>` stays synchronous
6. **Backward Incompatible**: Alpha library, clean break acceptable
7. **Preserve Emission Types**: Keep `.state`, `.perform`, `.observe`, `.merge` semantics

### Benefits

1. **Simpler Effects**: No state reading or construction - just return actions
2. **Easier Scoping**: Action mapping (`child.map { .child($0) }`) vs state adaptation
3. **Better Testability**: Assert actions emitted, not full state
4. **Single Source of Truth**: Interactor is the only place state changes
5. **No Race Conditions**: Effects can't read stale state or clobber each other
6. **Industry Alignment**: Matches TCA's proven Effect<Action> model

## Existing Codebase Analysis

### Current Emission<State> Pattern

**Emission.swift (lines 61-134)**:
```swift
public struct Emission<State: Sendable>: Sendable {
    public enum Kind: Sendable {
        case state
        case perform(work: @Sendable (DynamicState<State>, Send<State>) async -> Void)
        case observe(stream: @Sendable (DynamicState<State>, Send<State>) async -> Void)
        case merge([Emission<State>])
    }
}
```

Effects receive `DynamicState<State>` and `Send<State>`.

**Usage in Debounce (lines 50-82)**:
```swift
return .observe { dynamicState, send in
    await debouncer.debounce {
        var currentState = await dynamicState.current  // Read state
        let childEmission = child.interact(state: &currentState, action: action)
        await send(currentState)  // Send state
        // ...
    }
}
```

Higher-order interactors like `Debounce` must manually read state, process, and send.

### Pattern Evaluation: State Emission is Wrong Abstraction

**Red Flags**:
1. **Dual state mutation points**: Interactor (sync) AND effects (async) can change state
2. **State reading in effects**: Effects need `DynamicState` - why should effects care about current state?
3. **Complex scoping**: State transformation required for When/Scope (see When plan line 24-40)
4. **Race conditions**: Multiple effects reading/writing state can conflict
5. **Testing complexity**: Must assert on full state objects, not intent (actions)

**Why This Happened**:
Initial design treated effects as "async state producers" (like async interactors). But effects should be "action producers" - they observe the world and tell the interactor what happened via actions. The interactor decides how actions affect state.

**Better Pattern**:
Effects return actions, interactor is single source of state changes. This matches TCA's model (where "Reducer" = Uno's "Interactor"), proven at scale.

## Architectural Approaches

### Approach 1: Pure Action-Based Effects (Recommended)

**Overview**: Effects emit actions, interactor processes all actions synchronously.

**Architecture**:
```
┌─────────────────────────────────────────────────────────────┐
│                      SwiftUI View                            │
└────────────────────┬────────────────────────────────────────┘
                     │ .buttonTapped
                     ↓
┌─────────────────────────────────────────────────────────────┐
│                       ViewModel                              │
│  sendViewEvent(.buttonTapped)                                │
│  1. emission = interactor.interact(state: &state, .buttonTapped)
│  2. Spawn tasks from emission                                │
│  3. Tasks emit actions back to interactor                    │
└────────────────────┬────────────────────────────────────────┘
                     │ SYNC
                     ↓
┌─────────────────────────────────────────────────────────────┐
│                      Interactor                              │
│  interact(state: inout State, action: Action) -> Emission<Action>
│                                                              │
│  switch action {                                             │
│  case .buttonTapped:                                         │
│      state.isLoading = true                                  │
│      return .perform {                                       │
│          let data = await api.fetch()                        │
│          return .fetchCompleted(data)  // Emit action!       │
│      }                                                       │
│  case .fetchCompleted(let data):                             │
│      state.isLoading = false                                 │
│      state.data = data                                       │
│      return .state                                           │
│  }                                                           │
└─────────────────────────────────────────────────────────────┘
```

**Key Components**:

1. **New Emission<Action>**:
```swift
public struct Emission<Action: Sendable>: Sendable {
    public enum Kind: Sendable {
        case none  // No action to emit
        case action(Action)  // Emit single action
        case perform(work: @Sendable () async -> Action?)
        case observe(stream: @Sendable () async -> AsyncStream<Action>)
        case merge([Emission<Action>])
    }
}
```

2. **Simpler Effect Signatures**:
```swift
// Before: DynamicState + Send
.perform { state, send in
    let data = await api.fetch()
    var current = await state.current
    current.data = data
    await send(current)
}

// After: Just return action
.perform {
    let data = await api.fetch()
    return .fetchCompleted(data)
}
```

3. **Action Scoping**:
```swift
extension Emission {
    func map<ParentAction>(_ transform: @escaping (Action) -> ParentAction) -> Emission<ParentAction> {
        switch kind {
        case .none: return .none
        case .action(let action): return .action(transform(action))
        case .perform(let work):
            return .perform {
                guard let action = await work() else { return nil }
                return transform(action)
            }
        case .observe(let stream):
            return .observe {
                await stream().map(transform)
            }
        case .merge(let emissions):
            return .merge(emissions.map { $0.map(transform) })
        }
    }
}
```

4. **ViewModel Processes Actions from Effects**:
```swift
private func spawnTasks(from emission: Emission<Action>) -> [Task<Void, Never>] {
    switch emission.kind {
    case .none:
        return []
    case .action(let action):
        // Immediately process action synchronously
        let innerEmission = interactor.interact(state: &domainState, action: action)
        viewStateReducer.reduce(domainState, into: &viewState)
        return spawnTasks(from: innerEmission)  // Recursive
    case .perform(let work):
        let task = Task { [weak self] in
            guard let action = await work() else { return }
            // Cooperative cancellation: check after await before processing
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                let emission = self.interactor.interact(state: &self.domainState, action: action)
                self.viewStateReducer.reduce(self.domainState, into: &self.viewState)
                let tasks = self.spawnTasks(from: emission)
                self.effectTasks.append(contentsOf: tasks)
            }
        }
        return [task]
    case .observe(let stream):
        let task = Task { [weak self] in
            for await action in await stream() {
                // Cooperative cancellation: check after each await
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let self else { return }
                    let emission = self.interactor.interact(state: &self.domainState, action: action)
                    self.viewStateReducer.reduce(self.domainState, into: &self.viewState)
                    let tasks = self.spawnTasks(from: emission)
                    self.effectTasks.append(contentsOf: tasks)
                }
            }
        }
        return [task]
    case .merge(let emissions):
        return emissions.flatMap { spawnTasks(from: $0) }
    }
}
```

**Pros**:
- **Simplest effects**: No `DynamicState`, no `Send`, just return actions
- **Trivial scoping**: `.map { .child($0) }`
- **Single source of truth**: All state changes in interactor
- **Best testability**: Assert actions, not state
- **No race conditions**: Effects can't clobber state
- **Industry proven**: TCA model

**Cons**:
- **More actions**: Need actions for effect results (e.g., `.fetchCompleted`)
- **Action namespace growth**: More actions in domain
- **Breaking change**: Complete rewrite of effects

**Trade-offs**:
- **Pro**: Cleaner architecture, simpler code, better tests
- **Pro**: Eliminates entire class of bugs (effect state races)
- **Con**: Requires adding "response" actions for every effect
- **Con**: More verbose action enums

---

### Approach 2: Hybrid Send-Based Effects

**Overview**: Effects still use `Send<Action>` but no `DynamicState`.

**Architecture**:
```swift
public struct Emission<Action: Sendable>: Sendable {
    public enum Kind: Sendable {
        case none
        case perform(work: @Sendable (Send<Action>) async -> Void)
        case observe(stream: @Sendable (Send<Action>) async -> Void)
        case merge([Emission<Action>])
    }
}

// Usage:
return .perform { send in
    let data = await api.fetch()
    send(.fetchCompleted(data))
    send(.otherAction)  // Can send multiple
}
```

**Pros**:
- Multiple actions from single effect
- More flexible than single-return

**Cons**:
- Still requires `Send` infrastructure
- More complex than single return
- When does effect finish? (Last send? Closure return?)
- Testing: must track all sends

**Trade-offs**:
- **Pro**: Flexibility to emit multiple actions
- **Con**: More complex control flow (when to finish?)
- **Risk**: Unclear lifecycle, harder to test

---

### Approach 3: Mutation-Based Hybrid (Not Recommended)

**Overview**: Keep `Emission<State>` but add action return.

**Architecture**:
```swift
return .perform { state, send in
    let data = await api.fetch()
    var current = await state.current
    current.data = data
    return [.fetchCompleted]  // Also return actions
}
```

**Pros**:
- Backward compatible (can migrate incrementally)

**Cons**:
- **Worst of both worlds**: Complexity of state + verbosity of actions
- Dual mutation points remain
- Scoping still complex
- Doesn't solve core problems

**Verdict**: Skip this approach - not worth the complexity.

---

## Recommended Approach: Pure Action-Based Effects (Approach 1)

Approach 1 is the clear winner because:

### Why This Approach

1. **Right Abstraction**: Effects observe the world and report what happened (actions), not decide what state should be (state mutation).

2. **Single Source of Truth**: Interactor is the ONLY place state changes. This makes code predictable and debuggable.

3. **Trivial Composition**: Action mapping is simple:
```swift
childEmission.map { .child($0) }  // vs complex state adaptation
```

4. **Better Testing**:
```swift
// Test just actions
#expect(harness.receivedActions == [.fetchStarted, .fetchCompleted])

// vs asserting full state objects
#expect(harness.states == [
    State(isLoading: true, data: nil),
    State(isLoading: false, data: expectedData)
])
```

5. **No Race Conditions**: Effects can't read stale state or overwrite each other.

6. **Proven Pattern**: TCA uses this model successfully at scale.

### Why Not Other Approaches

**Approach 2 (Send-Based)**:
- `Send` adds unnecessary indirection
- Unclear lifecycle (when is effect "done"?)
- Testing is harder (track all sends)
- Doesn't simplify as much as pure return

**Approach 3 (Hybrid)**:
- Keeps all the problems of current approach
- Adds action verbosity without benefits
- Dual mutation points create confusion

## Detailed Technical Design

### System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      User Action Flow                        │
│                                                              │
│  User Tap                                                    │
│     ↓                                                        │
│  SwiftUI View                                                │
│     ↓                                                        │
│  ViewModel.sendViewEvent(.buttonTapped)                      │
│     ↓                                                        │
│  Interactor.interact(state: &state, action: .buttonTapped)   │
│     ↓                                                        │
│  state.isLoading = true                                      │
│  return .perform { await api.fetch() -> .fetchCompleted }    │
│     ↓                                                        │
│  ViewModel spawns Task                                       │
│     ↓                                                        │
│  [Effect executes async]                                     │
│     ↓                                                        │
│  Effect returns .fetchCompleted(data)                        │
│     ↓                                                        │
│  ViewModel: sendViewEvent(.fetchCompleted(data))             │
│     ↓                                                        │
│  Interactor.interact(state: &state, .fetchCompleted(data))   │
│     ↓                                                        │
│  state.isLoading = false                                     │
│  state.data = data                                           │
│  return .none                                                │
└─────────────────────────────────────────────────────────────┘
```

### Component Design

#### 1. Core Emission<Action> Type

**File**: `Sources/UnoArchitecture/Domain/Emission.swift`

```swift
/// Describes how an interactor emits actions after processing an action.
///
/// `Emission<Action>` replaces `Emission<State>` in the new action-based architecture.
/// Effects now emit actions back to the interactor rather than emitting state directly.
///
/// ## Why Actions Instead of State?
///
/// **Before (State-based)**:
/// ```swift
/// return .perform { state, send in
///     let data = await api.fetch()
///     var current = await state.current  // Read state
///     current.data = data
///     current.isLoading = false
///     await send(current)  // Send full state
/// }
/// ```
///
/// **After (Action-based)**:
/// ```swift
/// return .perform {
///     let data = await api.fetch()
///     return .fetchCompleted(data)  // Just return action!
/// }
/// ```
///
/// Benefits:
/// - No need to read current state in effects
/// - Interactor is single source of truth for all state changes
/// - Trivial scoping: `.map { .child($0) }`
/// - Better testing: assert actions, not full state
/// - No race conditions from concurrent effects
public struct Emission<Action: Sendable>: Sendable {

    /// The kind of emission.
    public enum Kind: Sendable {
        /// No action to emit.
        case none

        /// Emit a single action immediately.
        case action(Action)

        /// Execute async work and return an action.
        ///
        /// The work closure returns `Action?`. If `nil`, no action is emitted
        /// (useful for cancelled operations or error handling).
        case perform(work: @Sendable () async -> Action?)

        /// Observe an async stream of actions.
        ///
        /// The stream closure returns `AsyncStream<Action>`. Each action in the
        /// stream is processed through the interactor.
        case observe(stream: @Sendable () async -> AsyncStream<Action>)

        /// Merge multiple emissions together.
        case merge([Emission<Action>])
    }

    let kind: Kind

    /// No action to emit.
    public static var none: Emission {
        Emission(kind: .none)
    }

    /// Emit a single action immediately.
    public static func action(_ action: Action) -> Emission {
        Emission(kind: .action(action))
    }

    /// Execute async work and emit the resulting action.
    ///
    /// ```swift
    /// return .perform {
    ///     let data = await api.fetch()
    ///     return .fetchCompleted(data)
    /// }
    /// ```
    public static func perform(_ work: @escaping @Sendable () async -> Action?) -> Emission {
        Emission(kind: .perform(work: work))
    }

    /// Observe an async stream and emit each action.
    ///
    /// ```swift
    /// return .observe {
    ///     AsyncStream { continuation in
    ///         for await location in locationManager.locations {
    ///             continuation.yield(.locationUpdated(location))
    ///         }
    ///     }
    /// }
    /// ```
    public static func observe(_ stream: @escaping @Sendable () async -> AsyncStream<Action>) -> Emission {
        Emission(kind: .observe(stream: stream))
    }

    /// Merge multiple emissions.
    public static func merge(_ emissions: [Emission<Action>]) -> Emission {
        Emission(kind: .merge(emissions))
    }

    /// Merge this emission with another.
    public func merging(with other: Emission<Action>) -> Emission<Action> {
        .merge([self, other])
    }
}
```

#### 2. Emission Mapping for Scoping

**File**: `Sources/UnoArchitecture/Domain/Emission.swift` (add extension)

```swift
// MARK: - Action Mapping

extension Emission {
    /// Transforms the actions in this emission.
    ///
    /// This is used by higher-order interactors like `When` to map child actions
    /// to parent actions:
    ///
    /// ```swift
    /// let childEmission = child.interact(state: &childState, action: childAction)
    /// return childEmission.map { .child($0) }  // Wrap in parent action
    /// ```
    ///
    /// Much simpler than state-based scoping which required complex state transformations!
    public func map<ParentAction>(_ transform: @escaping @Sendable (Action) -> ParentAction) -> Emission<ParentAction> {
        switch kind {
        case .none:
            return .none

        case .action(let action):
            return .action(transform(action))

        case .perform(let work):
            return .perform {
                guard let action = await work() else { return nil }
                return transform(action)
            }

        case .observe(let stream):
            return .observe {
                await AsyncStream { continuation in
                    let sourceStream = await stream()
                    Task {
                        for await action in sourceStream {
                            continuation.yield(transform(action))
                        }
                        continuation.finish()
                    }
                }
            }

        case .merge(let emissions):
            return .merge(emissions.map { $0.map(transform) })
        }
    }
}
```

#### 3. Updated Interactor Protocol

**File**: `Sources/UnoArchitecture/Domain/Interactor.swift`

**Changes**: Return type becomes `Emission<Action>`

```swift
public protocol Interactor<DomainState, Action> {
    associatedtype DomainState: Sendable
    associatedtype Action: Sendable
    associatedtype Body: Interactor

    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    /// Processes an action by mutating state and returning an emission.
    ///
    /// **NEW**: Returns `Emission<Action>` instead of `Emission<DomainState>`.
    ///
    /// Effects now emit actions back through the interactor:
    /// ```swift
    /// case .fetchData:
    ///     state.isLoading = true
    ///     return .perform {
    ///         let data = await api.fetch()
    ///         return .fetchCompleted(data)
    ///     }
    /// case .fetchCompleted(let data):
    ///     state.isLoading = false
    ///     state.data = data
    ///     return .none
    /// ```
    func interact(state: inout DomainState, action: Action) -> Emission<Action>
}

extension Interactor where Body: Interactor<DomainState, Action> {
    public func interact(state: inout DomainState, action: Action) -> Emission<Action> {
        body.interact(state: &state, action: action)
    }
}
```

#### 4. Updated ViewModel

**File**: `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift`

**Key Changes**:
- `spawnTasks` processes `Emission<Action>`
- Actions from effects are fed back through `interact`

```swift
@MainActor
public final class ViewModel<Action, DomainState, ViewState>: Observable, _ViewModel
where Action: Sendable, DomainState: Sendable, ViewState: ObservableState {
    private var _viewState: ViewState
    private var domainState: DomainState
    private var effectTasks: [Task<Void, Never>] = []

    private let interactor: AnyInteractor<DomainState, Action>
    private let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    private let areStatesEqual: (_ lhs: DomainState, _ rhs: DomainState) -> Bool

    // ... init methods unchanged ...

    @discardableResult
    public func sendViewEvent(_ event: Action) -> EventTask {
        let originalDomainState = domainState
        let emission = interactor.interact(state: &domainState, action: event)

        if !areStatesEqual(originalDomainState, domainState) {
            viewStateReducer.reduce(domainState, into: &viewState)
        }

        let tasks = spawnTasks(from: emission)
        effectTasks.append(contentsOf: tasks)

        guard !tasks.isEmpty else {
            return EventTask(rawValue: nil)
        }

        let compositeTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for task in tasks {
                    group.addTask { await task.value }
                }
            }
        }

        return EventTask(rawValue: compositeTask)
    }

    /// Spawns tasks from an action-based emission.
    ///
    /// Actions returned by effects are fed back through the interactor.
    private func spawnTasks(from emission: Emission<Action>) -> [Task<Void, Never>] {
        switch emission.kind {
        case .none:
            return []

        case .action(let action):
            // Process action immediately and recursively spawn its effects
            let innerEmission = interactor.interact(state: &domainState, action: action)
            viewStateReducer.reduce(domainState, into: &viewState)
            return spawnTasks(from: innerEmission)

        case .perform(let work):
            let task = Task { [weak self] in
                guard let action = await work() else { return }
                // Cooperative cancellation: check after await before processing
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    let emission = self.interactor.interact(state: &self.domainState, action: action)
                    if !self.areStatesEqual(self.domainState, self.domainState) {
                        self.viewStateReducer.reduce(self.domainState, into: &self.viewState)
                    }
                    let tasks = self.spawnTasks(from: emission)
                    self.effectTasks.append(contentsOf: tasks)
                }
            }
            return [task]

        case .observe(let stream):
            let task = Task { [weak self] in
                for await action in await stream() {
                    // Cooperative cancellation: check after each await
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        guard let self else { return }
                        let emission = self.interactor.interact(state: &self.domainState, action: action)
                        if !self.areStatesEqual(self.domainState, self.domainState) {
                            self.viewStateReducer.reduce(self.domainState, into: &self.viewState)
                        }
                        let tasks = self.spawnTasks(from: emission)
                        self.effectTasks.append(contentsOf: tasks)
                    }
                }
            }
            return [task]

        case .merge(let emissions):
            return emissions.flatMap { spawnTasks(from: $0) }
        }
    }

    deinit {
        effectTasks.forEach { $0.cancel() }
    }
}
```

#### 5. Higher-Order Interactors with Action Mapping

**Merge** (unchanged logic, return type changes):
```swift
public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor, Sendable {
    private let i0: I0
    private let i1: I1

    public func interact(state: inout I0.DomainState, action: I0.Action) -> Emission<I0.Action> {
        let emission0 = i0.interact(state: &state, action: action)
        let emission1 = i1.interact(state: &state, action: action)
        return .merge([emission0, emission1])
    }
}
```

**When** (trivially simple with action mapping):
```swift
public struct When<ParentState, ParentAction, Child: Interactor>: Interactor, Sendable {
    private let toChildState: WritableKeyPath<ParentState, Child.DomainState>
    private let toChildAction: AnyCasePath<ParentAction, Child.Action>
    private let toParentAction: (Child.Action) -> ParentAction
    private let child: Child

    public func interact(state: inout ParentState, action: ParentAction) -> Emission<ParentAction> {
        guard let childAction = toChildAction.extract(from: action) else {
            return .none
        }

        var childState = state[keyPath: toChildState]
        let childEmission = child.interact(state: &childState, action: childAction)
        state[keyPath: toChildState] = childState

        // Trivial action mapping!
        return childEmission.map(toParentAction)
    }
}
```

**Debounce** (simpler without state management):
```swift
public struct Debounce<C: Clock, Child: Interactor>: Interactor, Sendable {
    private let child: Child
    private let debouncer: Debouncer<C>

    public func interact(state: inout Child.DomainState, action: Child.Action) -> Emission<Child.Action> {
        // Debounce the action, then forward to child
        return .perform { [child] in
            await debouncer.debounce {
                // When debounce fires, return the action to process
                return action
            }
        }
        // Note: This approach means debounce just delays the action.
        // The actual state mutation happens when the delayed action is processed.
    }
}
```

Actually, Debounce needs rethinking for action-based model. See Open Questions.

### Data Models

**Core Types**:

```swift
// Emission.swift
public struct Emission<Action: Sendable>: Sendable {
    public enum Kind: Sendable {
        case none
        case action(Action)
        case perform(work: @Sendable () async -> Action?)
        case observe(stream: @Sendable () async -> AsyncStream<Action>)
        case merge([Emission<Action>])
    }
    let kind: Kind
}

// Interactor.swift
public protocol Interactor<DomainState, Action> {
    func interact(state: inout DomainState, action: Action) -> Emission<Action>
}

// No more DynamicState in effects!
// No more Send<State> in effects!
```

### Testing Architecture

**Action-Based Testing**:

```swift
@Test
func testAsyncFetch() async throws {
    let harness = InteractorTestHarness(
        initialState: DataState(),
        interactor: DataInteractor()
    )

    // Send initial action
    await harness.send(.fetchData)

    // Assert state changed synchronously
    #expect(harness.currentState.isLoading == true)

    // Wait for effect to complete
    await harness.awaitInFlight()

    // Assert final state after effect action processed
    #expect(harness.currentState.isLoading == false)
    #expect(harness.currentState.data != nil)

    // NEW: Can also assert actions received
    #expect(harness.receivedActions == [
        .fetchData,
        .fetchCompleted(expectedData)
    ])
}
```

**Test Harness Update**:

```swift
@MainActor
public final class InteractorTestHarness<State: Sendable, Action: Sendable> {
    private var state: State
    private let interactor: AnyInteractor<State, Action>
    private var stateHistory: [State] = []
    private var actionHistory: [Action] = []  // NEW
    private var effectTasks: [Task<Void, Never>] = []

    // ... existing methods ...

    /// All actions received (including from effects).
    public var receivedActions: [Action] {
        actionHistory
    }

    public func send(_ action: Action) -> EventTask {
        actionHistory.append(action)
        let emission = interactor.interact(state: &state, action: action)
        appendToHistory()

        let tasks = spawnTasks(from: emission)
        // ... spawn logic ...
    }

    private func spawnTasks(from emission: Emission<Action>) -> [Task<Void, Never>] {
        switch emission.kind {
        case .none:
            return []
        case .action(let action):
            // Process immediately
            _ = send(action)
            return []
        case .perform(let work):
            let task = Task { [weak self] in
                guard let action = await work() else { return }
                // Cooperative cancellation: check after await
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    _ = self?.send(action)
                }
            }
            effectTasks.append(task)
            return [task]
        case .observe(let stream):
            let task = Task { [weak self] in
                for await action in await stream() {
                    // Cooperative cancellation: check after each await
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        _ = self?.send(action)
                    }
                }
            }
            effectTasks.append(task)
            return [task]
        case .merge(let emissions):
            return emissions.flatMap { spawnTasks(from: $0) }
        }
    }

    /// Wait for all in-flight effects to complete.
    public func awaitInFlight() async {
        await withTaskGroup(of: Void.self) { group in
            for task in effectTasks {
                group.addTask { await task.value }
            }
        }
        effectTasks.removeAll()
    }
}
```

### Migration Strategy

Since this is alpha software, we do a clean break.

**Phase 1: Core Changes**
1. Change `Emission<State>` to `Emission<Action>`
2. Remove `DynamicState` parameter from effect closures
3. Remove `Send<State>` parameter from effect closures
4. Update return types in `Interactor` protocol

**Phase 2: ViewModel Updates**
1. Update `spawnTasks` to process `Emission<Action>`
2. Add action feedback loop (effect actions → `interact`)
3. Remove `makeDynamicState()` and `makeSend()` methods

**Phase 3: Higher-Order Interactors**
1. Update `Merge`, `MergeMany` (simple - just return types change)
2. Rewrite `When` to use `.map` for action transformation
3. Redesign `Debounce` (see Open Questions)

**Phase 4: Testing Infrastructure**
1. Add `receivedActions` tracking to `InteractorTestHarness`
2. Add `awaitInFlight()` helper
3. Update example tests to action-based assertions

**Phase 5: Consumer Migration**
1. Consumers update effects to return actions
2. Consumers add "response" actions for effect results
3. Update tests to assert actions instead of states

**Example Migration**:

```swift
// BEFORE
case .fetch:
    state.isLoading = true
    return .perform { state, send in
        let data = await api.fetch()
        var current = await state.current
        current.isLoading = false
        current.data = data
        await send(current)
    }

// AFTER
enum Action {
    case fetch
    case fetchCompleted(Data)  // NEW
    case fetchFailed(Error)    // NEW
}

case .fetch:
    state.isLoading = true
    return .perform {
        do {
            let data = try await api.fetch()
            return .fetchCompleted(data)
        } catch {
            return .fetchFailed(error)
        }
    }
case .fetchCompleted(let data):
    state.isLoading = false
    state.data = data
    return .none
case .fetchFailed(let error):
    state.isLoading = false
    state.error = error
    return .none
```

## Trade-offs Analysis

### Advantages of Emission<Action>

1. **Simpler Effects**: No state reading or construction - just return actions
2. **Single Source of Truth**: All state changes in interactor, effects can't race
3. **Trivial Scoping**: `.map { .child($0) }` vs complex state transformations
4. **Better Testing**: Assert actions (intent) not state (implementation)
5. **Clearer Intent**: Actions describe what happened, not how to update state
6. **No DynamicState**: Eliminates entire subsystem

### Considerations

1. **More Actions**: Need response actions for every effect
   - Mitigation: This is actually good - explicit modeling of async outcomes
2. **Action Namespace Growth**: More cases in action enums
   - Mitigation: Use nested enums for feature slicing
3. **Breaking Change**: All existing effects must be rewritten
   - Mitigation: Alpha library, clean break acceptable

### Comparison to Current

| Aspect | Current (State) | Proposed (Action) |
|--------|-----------------|-------------------|
| Effect signature | `(DynamicState, Send) async -> Void` | `() async -> Action?` |
| State reading | `await state.current` | N/A |
| State writing | `send(newState)` | N/A |
| Scoping | State transformation (complex) | Action mapping (`.map`) |
| Testing | Assert full states | Assert actions |
| Race conditions | Possible (effects read/write) | Impossible (interactor only) |
| Source of truth | Interactor + Effects | Interactor only |

## Open Questions

### 1. How should Debounce work with action-based model?

**Option A: Delay Action Processing**
```swift
// Debounce delays when action is processed
return .perform {
    await debouncer.debounce {
        return action  // Return delayed action
    }
}
```
Problem: State mutation happens when debounced action is processed, but by then the user may have taken other actions.

**Option B: Immediate State Mutation, Delayed Effect**
```swift
public func interact(state: inout State, action: Action) -> Emission<Action> {
    // Update state immediately
    let childEmission = child.interact(state: &state, action: action)

    // But debounce any effects
    guard case .perform(let work) = childEmission.kind else {
        return childEmission
    }

    return .perform {
        await debouncer.debounce {
            await work()
        }
    }
}
```

**Recommendation**: Probably Option B for most cases, but this needs design work. Defer to separate task.

### 2. Should we support multiple actions from one effect?

**Current Design**: Single `Action?` return
**Alternative**: `[Action]` or `AsyncStream<Action>`

```swift
// Multi-action:
return .perform {
    let data = await api.fetch()
    return [.fetchCompleted(data), .markLastFetchTime]
}

// Or already supported via .observe:
return .observe {
    AsyncStream { continuation in
        let data = await api.fetch()
        continuation.yield(.fetchCompleted(data))
        continuation.yield(.markLastFetchTime)
        continuation.finish()
    }
}
```

**Recommendation**: Use `.observe` for multiple actions. Keep `.perform` simple (single action). If you need multiple, emit an action that triggers another emission.

### 3. Can effects see state at all?

In pure action model, effects shouldn't read state. But some effects legitimately need state (e.g., "fetch page N where N is current page").

**Option A**: Capture state at emission creation
```swift
case .fetchNextPage:
    let currentPage = state.currentPage
    return .perform {
        let data = await api.fetch(page: currentPage + 1)
        return .fetchCompleted(data, page: currentPage + 1)
    }
```

**Option B**: Pass state in action
```swift
case .fetchNextPage(let page):
    return .perform {
        let data = await api.fetch(page: page)
        return .fetchCompleted(data, page: page)
    }
```

**Recommendation**: Use Option A (capture). This is cleaner and the interactor decides what state to pass.

## Implementation Roadmap

### Phase 1: Core Emission Changes
**Goal**: Update `Emission` type and remove `DynamicState`/`Send`.

**Tasks**:
- [ ] Update `Emission<State>` to `Emission<Action>`
- [ ] Change effect signatures to `() async -> Action?`
- [ ] Add `.none` and `.action` cases
- [ ] Add `.map` method for action transformation
- [ ] Remove `DynamicState` usage
- [ ] Remove `Send` usage

**Files**:
- `Sources/UnoArchitecture/Domain/Emission.swift`
- `Sources/UnoArchitecture/Domain/DynamicState.swift` (delete?)
- `Sources/UnoArchitecture/Internal/Send.swift` (delete?)

**Testing**: Update unit tests for Emission

---

### Phase 2: Interactor Protocol Update
**Goal**: Update protocol to return `Emission<Action>`.

**Tasks**:
- [ ] Update `Interactor` protocol signature
- [ ] Update `AnyInteractor` wrapper
- [ ] Update default implementations

**Files**:
- `Sources/UnoArchitecture/Domain/Interactor.swift`

**Testing**: Verify protocol compiles

---

### Phase 3: ViewModel Rewrite
**Goal**: Process actions from effects back through interactor.

**Tasks**:
- [ ] Update `spawnTasks` to process `Emission<Action>`
- [ ] Add action feedback loop
- [ ] Remove `makeDynamicState()` and `makeSend()`
- [ ] Update effect lifecycle management

**Files**:
- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift`

**Testing**: Integration tests with ViewModel + Interactor

---

### Phase 4: Higher-Order Interactors
**Goal**: Update composition interactors for action-based model.

**Tasks**:
- [ ] Update `Merge` (trivial - just return type)
- [ ] Update `MergeMany` (trivial - just return type)
- [ ] Rewrite `When` with `.map` for action transformation
- [ ] Defer `Debounce` redesign (needs separate task)

**Files**:
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/Merge.swift`
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/MergeMany.swift`
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/Debounce.swift` (stub out)

**Testing**: Composition tests with action assertions

---

### Phase 5: Testing Infrastructure
**Goal**: Add action tracking to test harness.

**Tasks**:
- [ ] Add `receivedActions` tracking
- [ ] Add `awaitInFlight()` helper
- [ ] Update test harness to process action emissions
- [ ] Add action assertion helpers

**Files**:
- `Sources/UnoArchitecture/Testing/InteractorTestHarness.swift`

**Testing**: Test harness meta-tests

---

### Phase 6: Example Updates
**Goal**: Migrate example code to action-based model.

**Tasks**:
- [ ] Update example interactors
- [ ] Add response actions for effects
- [ ] Update tests to assert actions
- [ ] Update documentation

**Files**:
- `Tests/**/*Tests.swift`
- Example app code

**Testing**: All tests pass

---

## Major Pitfalls to Avoid

### 1. Effect State Reading

**Pitfall**: Trying to read state in effects
```swift
return .perform { state in  // ❌ No state parameter!
    let data = await api.fetch(state.currentPage)
    return .fetchCompleted(data)
}
```

**Solution**: Capture state at emission creation
```swift
let currentPage = state.currentPage
return .perform {  // ✅ Capture in closure
    let data = await api.fetch(currentPage)
    return .fetchCompleted(data)
}
```

### 2. Forgetting Response Actions

**Pitfall**: Effect returns nothing
```swift
return .perform {
    await api.fetch()
    return nil  // ❌ What happens after fetch?
}
```

**Solution**: Always return action
```swift
enum Action {
    case fetch
    case fetchCompleted(Data)
    case fetchFailed(Error)
}

return .perform {
    do {
        let data = try await api.fetch()
        return .fetchCompleted(data)
    } catch {
        return .fetchFailed(error)
    }
}
```

### 3. Infinite Loops

**Pitfall**: Action triggers itself
```swift
case .fetch:
    return .perform { .fetch }  // ❌ Infinite loop!
```

**Solution**: Use distinct actions
```swift
case .fetch:
    return .perform { .fetchCompleted(data) }
case .fetchCompleted:
    return .none
```

### 4. State Mutation in Effects

**Pitfall**: Trying to mutate state in effect
```swift
return .perform {
    // Can't access state here!
    return .fetchCompleted(data)
}
```

**Solution**: All state changes in interactor
```swift
case .fetchCompleted(let data):
    state.data = data  // ✅ Mutate in interactor
    return .none
```

### 5. Debounce Timing

**Pitfall**: Debouncing actions loses state context
```swift
// When debounced action fires, state may have changed
return .perform {
    await debouncer.debounce {
        return .processOldAction  // Stale context!
    }
}
```

**Solution**: Capture relevant state, or redesign Debounce (see Open Questions)

## References

### TCA Effect System
- [TCA Effect Documentation](https://pointfreeco.github.io/swift-composable-architecture/main/documentation/composablearchitecture/effect)
- [TCA Reducer Protocol](https://pointfreeco.github.io/swift-composable-architecture/main/documentation/composablearchitecture/reducer)

### Elm Architecture
- [Elm Commands](https://guide.elm-lang.org/effects/commands.html) - Original action-based effects

### Redux
- [Redux Actions](https://redux.js.org/tutorials/fundamentals/part-2-concepts-data-flow#actions) - Action-centric state management

### Martin Fowler
- [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html) - Events (actions) as source of truth
- [Command Query Responsibility Segregation](https://martinfowler.com/bliki/CQRS.html) - Separating commands (actions) from queries (state)

### Related Uno Documentation
- Current Emission Design: `Sources/UnoArchitecture/Domain/Emission.swift`
- Sync Interactor API Design: `thoughts/shared/research/2025-01-02_sync_interactor_api_design.md`
- When Interactor Design: `thoughts/shared/plans/2026-01-04_when_sync_api.md`

---

**Document Status**: COMPLETE - Ready for Review
**Recommendation**: Proceed with Approach 1 (Pure Action-Based Effects)
**Next Steps**:
1. Team review and approve approach
2. Prototype Phase 1 (Core Emission Changes)
3. Validate with simple example before full migration

**Breaking Change**: YES - Requires major version bump (3.0)

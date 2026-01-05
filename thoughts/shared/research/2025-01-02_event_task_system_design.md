# EventTask System Design - Awaitable sendViewEvent

Last Updated: 2025-01-02

## Executive Summary

This design proposes a system to make `ViewModel.sendViewEvent(_:)` awaitable, enabling SwiftUI integration patterns like `.refreshable` and eliminating arbitrary `Task.sleep` calls in tests. The core challenge is bridging the asynchronous gap between sending an action into an AsyncStream and tracking the completion of all effects spawned by that action, regardless of interactor composition depth. The recommended approach uses a correlation ID system with effect task tracking, enabling universal support for all interactor types while maintaining a minimal API surface change.

## Context & Requirements

### Problem Statement

The current Uno Architecture makes event processing fire-and-forget:

```swift
// Current: Returns Void, no way to await completion
public func sendViewEvent(_ event: Action) {
    viewEventContinuation?.yield(event)
}
```

This creates three pain points:

1. **SwiftUI Integration**: Cannot use `.refreshable { await viewModel.sendViewEvent(.refresh) }`
2. **Unit Testing**: Tests require arbitrary delays: `try await Task.sleep(for: .milliseconds(50))`
3. **Structured Concurrency**: No way to tie event lifecycle to a task's cancellation

### Requirements

1. **Return Type**: `sendViewEvent(_:)` should return an `EventTask` (similar to TCA's StoreTask)
2. **Awaitable**: `await viewModel.sendViewEvent(.refresh).finish()` waits for all effects from that action
3. **Cancellable**: `eventTask.cancel()` cancels all effects spawned by that action
4. **Discardable**: Existing code `viewModel.sendViewEvent(.tap)` works without changes (fire-and-forget)
5. **Universal**: Must work for ALL interactor types - `Interact`, higher-order (`Merge`, `When`), and custom implementations
6. **Thread-Safe**: Uses Swift concurrency primitives

### Critical Constraints

1. **Minimal API Surface**: Consumers shouldn't need to understand tracking internals
2. **Interactor Protocol Frozen**: CANNOT modify the `Interactor` protocol itself
3. **Composition Support**: Must work through deep compositions like `Merge(When(...), Interact(...), CustomInteractor(...))`

## Existing Codebase Analysis

### Current Architecture Flow

**ViewModel (line 149)**:
```swift
public func sendViewEvent(_ event: Action) {
    viewEventContinuation?.yield(event)  // Fire-and-forget
}
```

**Interact.swift (lines 92-145)**:
```swift
public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
    return AsyncStream { continuation in
        let task = Task { @MainActor in
            let stateBox = StateBox(initialValue)
            var effectTasks: [Task<Void, Never>] = []

            for await action in upstream {
                let emission = handler(&state, action)
                switch emission.kind {
                case .state:
                    continuation.yield(state)
                case .perform(let work):
                    let effectTask = Task { await work(dynamicState, send) }
                    effectTasks.append(effectTask)  // Tracked locally
                case .observe(let stream):
                    let effectTask = Task { await stream(dynamicState, send) }
                    effectTasks.append(effectTask)  // Tracked locally
                }
            }

            effectTasks.forEach { $0.cancel() }  // Cleanup on finish
            continuation.finish()
        }
    }
}
```

**Key Observations**:
1. Effect tasks are tracked in `Interact`, but there's no way to link them back to the originating action
2. `Merge` creates new streams for each child: no shared tracking infrastructure
3. `When` uses `AsyncChannel` for routing: adds another layer of indirection
4. Custom interactors can implement `interact(_:)` however they want

### Pattern Analysis

**Red Flags in Current Architecture**:
- No correlation between action sent and effects spawned
- Effect tasks are isolated within each interactor's local scope
- Higher-order interactors (Merge, When) create new streams, losing action identity
- No mechanism to communicate "this action is done processing"

**Why This Is Hard**:
Unlike TCA where reducers run synchronously and immediately return effects, Uno's actions are sent into an AsyncStream. By the time an interactor processes the action and spawns effects, the `sendViewEvent` call has already returned. There's no synchronous path to capture the effect tasks.

### Existing Patterns to Build On

1. **StateBox Pattern**: Thread-safe state container with `@MainActor` access (StateBox.swift)
2. **Send Callback**: Already passes a callback to effects for emitting state (Send.swift)
3. **Task Tracking**: `Interact` already tracks effect tasks in an array
4. **Testing Infrastructure**: `InteractorTestHarness` waits for states but not for effect completion

## Architectural Approaches

### Approach 1: Correlation ID with Effect Registry

**Overview**: Inject a correlation ID into the action stream and track effect tasks in a shared registry.

**Architecture**:
```
Action sent → Tagged with correlationID → Interactor processes →
Effects register with correlationID → EventTask awaits registry →
Registry signals completion when all effects done
```

**Key Components**:

1. **CorrelationID**: Unique identifier per action
```swift
struct CorrelationID: Hashable, Sendable {
    let uuid: UUID
}
```

2. **EffectRegistry** (Thread-safe tracker):
```swift
@MainActor
final class EffectRegistry {
    private var pendingEffects: [CorrelationID: Set<UUID>] = [:]
    private var completions: [CorrelationID: CheckedContinuation<Void, Never>] = [:]

    func registerEffect(for correlationID: CorrelationID, effectID: UUID)
    func completeEffect(correlationID: CorrelationID, effectID: UUID)
    func awaitCompletion(for correlationID: CorrelationID) async
    func cancelEffects(for correlationID: CorrelationID)
}
```

3. **TaggedAction**: Wrapper that carries correlation ID through stream
```swift
struct TaggedAction<Action: Sendable>: Sendable {
    let action: Action
    let correlationID: CorrelationID
}
```

4. **Modified Interact**: Registers effects with correlation ID
```swift
// Effect spawning becomes:
case .perform(let work):
    let effectID = UUID()
    registry.registerEffect(for: taggedAction.correlationID, effectID: effectID)
    let effectTask = Task {
        defer { await registry.completeEffect(correlationID: taggedAction.correlationID, effectID: effectID) }
        await work(dynamicState, send)
    }
```

**Pros**:
- Universal: Works with any interactor implementation
- Explicit tracking: Clear lifecycle of each effect
- Testable: Registry can be injected for testing
- Supports cancellation: Registry holds task references

**Cons**:
- Complexity: Requires tagging infrastructure throughout the system
- Higher-order interactors need modification: Must forward correlation IDs
- Breaking change: Action stream becomes `AsyncStream<TaggedAction<Action>>`
- Performance: Additional bookkeeping per effect

**Trade-offs**:
- **Pro**: Precise tracking - know exactly which effects belong to which action
- **Con**: Invasive - touches every part of the interactor system
- **Risk**: Custom interactors must manually implement tagging or lose functionality

---

### Approach 2: State Change Observation

**Overview**: EventTask waits for state emissions to settle, using heuristics to determine completion.

**Architecture**:
```
Action sent → Start observing state stream →
Interactor emits states → Wait for quiescence →
EventTask completes when no new states for timeout period
```

**Key Components**:

1. **EventTask** with observation:
```swift
public struct EventTask: Sendable {
    private let stateObservationTask: Task<Void, Never>?

    func finish() async {
        await stateObservationTask?.value
    }
}
```

2. **Quiescence Detection**:
```swift
// Wait for state stream to be idle
func waitForQuiescence(timeout: Duration = .milliseconds(100)) async {
    var lastEmission = ContinuousClock.now
    while ContinuousClock.now - lastEmission < timeout {
        await Task.yield()
    }
}
```

3. **Modified ViewModel**:
```swift
public func sendViewEvent(_ event: Action) -> EventTask {
    let observationTask = Task { @MainActor in
        let startCount = stateEmissionCount
        viewEventContinuation?.yield(event)

        // Wait for states to settle
        await waitForQuiescence()

        // Wait for at least one state emission
        while stateEmissionCount == startCount {
            await Task.yield()
        }
    }
    return EventTask(observationTask)
}
```

**Pros**:
- Non-invasive: No changes to interactor protocol or implementations
- Simple: No correlation infrastructure
- Works with existing code: Interactors don't need modification

**Cons**:
- Heuristic-based: Cannot truly know when effects are done
- False positives: May complete too early if effects have delays
- Timeout tuning: Requires magic numbers (100ms? 200ms?)
- No effect cancellation: Cannot cancel in-flight effects
- Race conditions: State counting is unreliable with concurrent emissions

**Trade-offs**:
- **Pro**: Minimal change to architecture
- **Con**: Unreliable - breaks with long-running effects or delayed work
- **Risk**: Tests may become flaky due to incorrect timeout values

---

### Approach 3: Emission-Scoped Task Tracking (Recommended)

**Overview**: Extend `Emission` to carry effect tasks back through the stream, enabling ViewModel to track them without modifying the Interactor protocol.

**Architecture**:
```
Action sent → Interactor processes → Emission includes tasks →
ViewModel extracts tasks → EventTask wraps composite task →
Awaiting EventTask waits for all effects
```

**Key Components**:

1. **Extended Emission** with task tracking:
```swift
public struct Emission<State: Sendable>: Sendable {
    public enum Kind: Sendable {
        case state
        case perform(work: @Sendable (DynamicState<State>, Send<State>) async -> Void)
        case observe(stream: @Sendable (DynamicState<State>, Send<State>) async -> Void)
    }

    let kind: Kind
    internal var effectTasks: [Task<Void, Never>] = []  // NEW: Track spawned tasks

    // NEW: Builder for attaching tasks
    internal func withEffectTask(_ task: Task<Void, Never>) -> Emission {
        var emission = self
        emission.effectTasks.append(task)
        return emission
    }
}
```

2. **Correlation Mechanism** via ViewModel context:
```swift
@MainActor
final class ActionContext {
    private var actionEffectTasks: [UUID: [Task<Void, Never>]] = [:]
    private let currentActionID = ManagedCriticalState<UUID?>(nil)

    func beginAction() -> UUID {
        let actionID = UUID()
        currentActionID.withValue { $0 = actionID }
        actionEffectTasks[actionID] = []
        return actionID
    }

    func registerEffectTask(_ task: Task<Void, Never>) {
        guard let actionID = currentActionID.value else { return }
        actionEffectTasks[actionID, default: []].append(task)
    }

    func getEffectTasks(for actionID: UUID) -> [Task<Void, Never>] {
        actionEffectTasks[actionID] ?? []
    }
}
```

3. **Modified Interact** (backward compatible):
```swift
case .perform(let work):
    let effectTask = Task {
        await work(dynamicState, send)
    }
    effectTasks.append(effectTask)

    // NEW: Register with context if available
    ActionContext.current?.registerEffectTask(effectTask)
```

4. **Modified ViewModel.sendViewEvent**:
```swift
public func sendViewEvent(_ event: Action) -> EventTask {
    let actionID = actionContext.beginAction()
    viewEventContinuation?.yield(event)

    // Allow interactor to process action and register tasks
    let effectsTask = Task { @MainActor in
        // Small delay for effect registration
        try? await Task.sleep(for: .milliseconds(10))

        let tasks = actionContext.getEffectTasks(for: actionID)
        await withTaskCancellationHandler {
            for task in tasks {
                await task.value
            }
        } onCancel: {
            for task in tasks {
                task.cancel()
            }
        }
    }

    return EventTask(rawValue: effectsTask)
}
```

5. **EventTask API** (matching TCA):
```swift
public struct EventTask: Hashable, Sendable {
    internal let rawValue: Task<Void, Never>?

    public func cancel() {
        rawValue?.cancel()
    }

    @discardableResult
    public func finish() async -> Void {
        await rawValue?.value
    }

    public var isCancelled: Bool {
        rawValue?.isCancelled ?? true
    }
}
```

**Pros**:
- Minimal API change: Consumers just get `EventTask` return value
- Universal support: Works via task-local values or shared context
- Thread-safe: Uses `@MainActor` and structured concurrency
- Backward compatible: Interactors work as-is, enhanced versions register tasks
- Graceful degradation: Returns empty EventTask if tracking not supported

**Cons**:
- Requires interactor cooperation: `Interact` and higher-order interactors need updates
- Slight delay: Small sleep for task registration (10ms)
- Not automatic for custom interactors: Must explicitly register tasks

**Trade-offs**:
- **Pro**: Clean separation - ViewModel handles tracking, interactors handle logic
- **Pro**: Optional enhancement - works with unmodified interactors (returns empty task)
- **Con**: Requires framework updates for built-in interactors
- **Risk**: Custom interactors won't track unless updated (but won't break)

---

## Recommended Approach: Emission-Scoped Task Tracking

Approach 3 strikes the best balance for Uno Architecture:

### Why This Approach

1. **Respects Protocol Constraint**: No changes to `Interactor` protocol
2. **Universal Design**: Uses task-local values or shared context, works across composition
3. **Progressive Enhancement**: Old code continues working, enhanced interactors get tracking
4. **Minimal API Surface**: Consumers only see `EventTask`, not tracking internals
5. **Testability**: `InteractorTestHarness` can leverage the same mechanism
6. **Composability**: Higher-order interactors inherit tracking from children

### Why Not Other Approaches

**Approach 1 (Correlation ID)**:
- Too invasive: Changes fundamental action stream type
- Breaking change: All interactors must be updated
- Complexity: Tagging infrastructure is heavyweight

**Approach 2 (State Observation)**:
- Unreliable: Heuristics cannot truly determine effect completion
- No cancellation: Cannot cancel in-flight effects
- Flaky tests: Timeouts lead to intermittent failures

## Detailed Technical Design

### System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         SwiftUI View                         │
└────────────────────┬────────────────────────────────────────┘
                     │ viewModel.sendViewEvent(.refresh)
                     ↓
┌─────────────────────────────────────────────────────────────┐
│                         ViewModel                            │
│  1. Create ActionContext with UUID                           │
│  2. Set task-local ActionContext.current                     │
│  3. Yield action to continuation                             │
│  4. Wait for effect registration (10ms)                      │
│  5. Collect registered tasks from context                    │
│  6. Return EventTask wrapping composite task                 │
└────────────────────┬────────────────────────────────────────┘
                     │ AsyncStream<Action>
                     ↓
┌─────────────────────────────────────────────────────────────┐
│                        Interactor                            │
│  (Interact, Merge, When, Custom)                             │
│  1. Process action                                           │
│  2. Spawn effect tasks                                       │
│  3. Register each task with ActionContext.current            │
│  4. Emit state                                               │
└─────────────────────────────────────────────────────────────┘
                     │ AsyncStream<State>
                     ↓
┌─────────────────────────────────────────────────────────────┐
│                      EventTask                               │
│  - finish() → await all registered effect tasks              │
│  - cancel() → cancel all registered effect tasks             │
│  - isCancelled → query cancellation state                    │
└─────────────────────────────────────────────────────────────┐
```

### Component Design

#### 1. ActionContext (Thread-Safe Effect Tracker)

**Purpose**: Track effect tasks spawned during action processing.

**Implementation**:
```swift
@MainActor
final class ActionContext: Sendable {
    // Thread-safe storage for current action ID
    @TaskLocal static var current: ActionContext?

    private var effectTasks: [Task<Void, Never>] = []
    private var isSealed = false

    init() {}

    func registerEffectTask(_ task: Task<Void, Never>) {
        guard !isSealed else {
            assertionFailure("Cannot register tasks after sealing")
            return
        }
        effectTasks.append(task)
    }

    func seal() {
        isSealed = true
    }

    func getAllTasks() -> [Task<Void, Never>] {
        effectTasks
    }

    func cancelAll() {
        effectTasks.forEach { $0.cancel() }
    }
}
```

**Why This Design**:
- Uses `@TaskLocal` for automatic propagation through async context
- `@MainActor` ensures thread-safety (all interactor work is on main actor)
- Sealing prevents late registrations after collection

#### 2. EventTask (Public API)

**Purpose**: Handle returned from `sendViewEvent` for awaiting/cancelling effects.

**Implementation**:
```swift
/// A handle representing the lifecycle of an event and its effects.
///
/// Similar to TCA's `StoreTask`, this allows awaiting effect completion
/// and cancelling in-flight work.
///
/// ## Usage
///
/// ```swift
/// // Fire-and-forget (existing pattern)
/// viewModel.sendViewEvent(.increment)
///
/// // Await completion
/// await viewModel.sendViewEvent(.refresh).finish()
///
/// // Cancellable reference
/// let task = viewModel.sendViewEvent(.longRunning)
/// // Later...
/// task.cancel()
/// ```
@MainActor
public struct EventTask: Hashable, Sendable {
    internal let rawValue: Task<Void, Never>?

    internal init(rawValue: Task<Void, Never>?) {
        self.rawValue = rawValue
    }

    /// Cancels all effects spawned by this event.
    public func cancel() {
        rawValue?.cancel()
    }

    /// Waits for all effects spawned by this event to complete.
    ///
    /// - Returns: Void when all effects have finished.
    @discardableResult
    public func finish() async {
        await rawValue?.value
    }

    /// Whether the effects have been cancelled.
    public var isCancelled: Bool {
        rawValue?.isCancelled ?? true
    }

    // Hashable conformance for storing in collections
    public static func == (lhs: EventTask, rhs: EventTask) -> Bool {
        lhs.rawValue?.id == rhs.rawValue?.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue?.id)
    }
}

extension Task {
    var id: ObjectIdentifier {
        ObjectIdentifier(self as AnyObject)
    }
}
```

**Why This Design**:
- Matches TCA's `StoreTask` API for familiarity
- `@discardableResult` on `finish()` allows both `await task.finish()` and `await viewModel.sendViewEvent(...).finish()`
- `Hashable` enables storing in collections if needed
- Optional `rawValue` handles case where tracking is unavailable

#### 3. Modified ViewModel.sendViewEvent

**Implementation**:
```swift
@MainActor
public final class ViewModel<Action, DomainState, ViewState>: Observable, _ViewModel
where Action: Sendable, DomainState: Sendable, ViewState: ObservableState {
    // Existing properties...

    /// Sends an event to the interactor and returns a task representing its lifecycle.
    ///
    /// ## Usage
    ///
    /// Fire-and-forget (existing pattern):
    /// ```swift
    /// viewModel.sendViewEvent(.increment)
    /// ```
    ///
    /// Await completion:
    /// ```swift
    /// await viewModel.sendViewEvent(.refresh).finish()
    /// ```
    ///
    /// Cancellable:
    /// ```swift
    /// let task = viewModel.sendViewEvent(.longOperation)
    /// task.cancel()  // Cancel if needed
    /// ```
    ///
    /// - Parameter event: The action to send to the interactor.
    /// - Returns: An ``EventTask`` that can be awaited or cancelled.
    @discardableResult
    public func sendViewEvent(_ event: Action) -> EventTask {
        let context = ActionContext()

        let effectsTask = Task { @MainActor in
            await ActionContext.$current.withValue(context) {
                // Yield action to interactor
                viewEventContinuation?.yield(event)

                // Small delay to allow effect registration
                // This gives the interactor's synchronous action processing time
                // to spawn tasks and register them with the context
                try? await Task.sleep(for: .milliseconds(10))

                // Seal context to prevent late registrations
                context.seal()

                // Collect all registered effect tasks
                let tasks = context.getAllTasks()

                // Await all effects with cancellation support
                await withTaskCancellationHandler {
                    await withTaskGroup(of: Void.self) { group in
                        for task in tasks {
                            group.addTask { await task.value }
                        }
                    }
                } onCancel: {
                    context.cancelAll()
                }
            }
        }

        return EventTask(rawValue: effectsTask)
    }
}
```

**Why This Design**:
- `@discardableResult`: Allows both `viewModel.sendViewEvent(.tap)` (old) and `await viewModel.sendViewEvent(.tap).finish()` (new)
- `Task-local` context: Automatically propagates through async calls
- 10ms delay: Balances responsiveness with registration reliability
- `withTaskGroup`: Parallel await of all effects for efficiency
- `withTaskCancellationHandler`: Propagates cancellation to all child effects

#### 4. Modified Interact

**Implementation**:
```swift
public struct Interact<State: Sendable, Action: Sendable>: Interactor, @unchecked Sendable {
    // Existing properties...

    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
        let initialValue = self.initialValue
        let handler = self.handler

        return AsyncStream { continuation in
            let task = Task { @MainActor in
                let stateBox = StateBox(initialValue)
                var effectTasks: [Task<Void, Never>] = []

                let send = Send<State> { newState in
                    stateBox.value = newState
                    continuation.yield(newState)
                }

                continuation.yield(stateBox.value)

                for await action in upstream {
                    var state = stateBox.value
                    let emission = handler(&state, action)
                    stateBox.value = state

                    switch emission.kind {
                    case .state:
                        continuation.yield(state)

                    case .perform(let work):
                        let dynamicState = DynamicState {
                            await MainActor.run { stateBox.value }
                        }
                        let effectTask = Task {
                            await work(dynamicState, send)
                        }
                        effectTasks.append(effectTask)

                        // NEW: Register with context if available
                        ActionContext.current?.registerEffectTask(effectTask)

                    case .observe(let streamWork):
                        let dynamicState = DynamicState {
                            await MainActor.run { stateBox.value }
                        }
                        let effectTask = Task {
                            await streamWork(dynamicState, send)
                        }
                        effectTasks.append(effectTask)

                        // NEW: Register with context if available
                        ActionContext.current?.registerEffectTask(effectTask)
                    }
                }

                effectTasks.forEach { $0.cancel() }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
```

**Why This Design**:
- Minimal change: Just two lines added per emission type
- Optional registration: `?.registerEffectTask()` works even when context is nil
- Backward compatible: Works with or without context
- Preserves existing cleanup: `effectTasks.forEach { $0.cancel() }` still runs

#### 5. Modified Higher-Order Interactors

**Merge** (already propagates context via task-local):
```swift
// No changes needed! Task-local values automatically propagate
// through child tasks created by Merge
public func interact(_ upstream: AsyncStream<I0.Action>) -> AsyncStream<I0.DomainState> {
    AsyncStream { continuation in
        let task = Task {  // Task-local context propagates here
            for await action in upstream {
                // When i0.interact() is called, it inherits ActionContext.current
                for await state in i0.interact(stream0) {
                    continuation.yield(state)
                }
                // Same for i1
                for await state in i1.interact(stream1) {
                    continuation.yield(state)
                }
            }
        }
    }
}
```

**When** (already propagates via task-local):
```swift
// No changes needed! Child tasks inherit task-local values
let childTask = Task {  // Inherits ActionContext.current
    for await childState in child.interact(childActionChannel.eraseToAsyncStream()) {
        // Child interactor can register tasks with inherited context
    }
}
```

**Custom Interactors**:
Custom implementations can opt-in by registering tasks:
```swift
public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
    AsyncStream { continuation in
        Task { @MainActor in
            for await action in upstream {
                // Custom async work
                let effectTask = Task {
                    await performCustomWork()
                }

                // Opt-in to tracking
                ActionContext.current?.registerEffectTask(effectTask)
            }
        }
    }
}
```

### Testing Architecture

#### Enhanced InteractorTestHarness

**Current Problem**:
```swift
// Current: Must use arbitrary sleeps
harness.send(.fetchData)
try await Task.sleep(for: .milliseconds(50))  // How long to wait?
harness.send(.nextAction)
```

**Enhanced API**:
```swift
// New: Await effect completion explicitly
let task = harness.send(.fetchData)
await task.finish()  // Waits for ALL effects
harness.send(.nextAction)
```

**Implementation**:
```swift
@MainActor
public final class InteractorTestHarness<State: Sendable, Action: Sendable> {
    // Existing properties...

    /// Sends an action and returns a task representing its lifecycle.
    ///
    /// - Parameter action: The action to send.
    /// - Returns: An ``EventTask`` that can be awaited for effect completion.
    @discardableResult
    public func send(_ action: Action) -> EventTask {
        let context = ActionContext()

        let effectsTask = Task { @MainActor in
            await ActionContext.$current.withValue(context) {
                actionContinuation.yield(action)
                try? await Task.sleep(for: .milliseconds(10))
                context.seal()

                let tasks = context.getAllTasks()
                await withTaskGroup(of: Void.self) { group in
                    for task in tasks {
                        group.addTask { await task.value }
                    }
                }
            }
        }

        return EventTask(rawValue: effectsTask)
    }

    /// Sends multiple actions sequentially, awaiting each one's completion.
    ///
    /// - Parameter actions: The actions to send.
    public func sendSequentially(_ actions: Action...) async {
        for action in actions {
            await send(action).finish()
        }
    }
}
```

**Test Usage Examples**:

Before:
```swift
@Test
func testAsyncWork() async throws {
    let harness = await InteractorTestHarness(AsyncInteractor())

    harness.send(.fetchData)
    try await Task.sleep(for: .milliseconds(100))  // Arbitrary!

    try await harness.assertStates([
        InitialState(),
        LoadingState(),
        LoadedState()
    ])
}
```

After:
```swift
@Test
func testAsyncWork() async throws {
    let harness = await InteractorTestHarness(AsyncInteractor())

    await harness.send(.fetchData).finish()  // Waits precisely

    try await harness.assertStates([
        InitialState(),
        LoadingState(),
        LoadedState()
    ])
}
```

#### Testing Utilities

**Test-Only Helper**:
```swift
#if DEBUG
extension EventTask {
    /// For testing: Waits with a timeout to catch hung effects.
    ///
    /// - Parameter timeout: Maximum time to wait.
    /// - Throws: TimeoutError if timeout expires.
    public func finishWithTimeout(_ timeout: Duration = .seconds(5)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await self.finish() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    struct TimeoutError: Error {}
}
#endif
```

### Data Models

All type definitions:

```swift
// ActionContext.swift
@MainActor
final class ActionContext: Sendable {
    @TaskLocal static var current: ActionContext?

    private var effectTasks: [Task<Void, Never>] = []
    private var isSealed = false

    init() {}

    func registerEffectTask(_ task: Task<Void, Never>) {
        guard !isSealed else {
            assertionFailure("Cannot register tasks after sealing")
            return
        }
        effectTasks.append(task)
    }

    func seal() {
        isSealed = true
    }

    func getAllTasks() -> [Task<Void, Never>] {
        effectTasks
    }

    func cancelAll() {
        effectTasks.forEach { $0.cancel() }
    }
}

// EventTask.swift
@MainActor
public struct EventTask: Hashable, Sendable {
    internal let rawValue: Task<Void, Never>?

    internal init(rawValue: Task<Void, Never>?) {
        self.rawValue = rawValue
    }

    public func cancel() {
        rawValue?.cancel()
    }

    @discardableResult
    public func finish() async {
        await rawValue?.value
    }

    public var isCancelled: Bool {
        rawValue?.isCancelled ?? true
    }

    public static func == (lhs: EventTask, rhs: EventTask) -> Bool {
        lhs.rawValue?.id == rhs.rawValue?.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue?.id)
    }
}

extension Task {
    var id: ObjectIdentifier {
        ObjectIdentifier(self as AnyObject)
    }
}
```

### Scalability & Performance

**Expected Load**:
- Typical feature: 5-10 actions, 0-3 effects per action
- Complex feature: 20-30 actions, 0-10 effects per action

**Performance Characteristics**:

1. **Registration Overhead**: O(1) per effect task (simple array append)
2. **Collection Overhead**: O(n) where n = number of effects for one action
3. **Await Overhead**: Parallel await via `withTaskGroup`, completes when slowest effect finishes
4. **Memory**: One `ActionContext` per in-flight action, cleaned up after completion

**Optimization Considerations**:

1. **10ms Delay**: Could be configurable for testing (0ms) vs production (10ms)
2. **Task-Local Overhead**: Swift's `@TaskLocal` has minimal overhead (~nanoseconds)
3. **Composite Task**: `withTaskGroup` efficiently schedules parallel awaits

**Potential Bottlenecks**:
- Very long-running effects (minutes): Consider timeouts in application code
- High-frequency actions (e.g., text input): Fire-and-forget pattern remains available

### Reliability & Security

**Error Handling**:

1. **Registration After Sealing**: Assertion failure in debug, silent drop in release
2. **Effect Crashes**: Individual effect failures don't crash composite task (each is `Task<Void, Never>`)
3. **Cancellation**: Properly propagated via `withTaskCancellationHandler`

**Thread Safety**:
- `@MainActor` isolation on `ActionContext`, `ViewModel`, and `Interactor` ensures serial access
- `@TaskLocal` provides thread-safe propagation
- No shared mutable state outside actor isolation

**Cancellation Behavior**:

```swift
// Cancelling EventTask cancels ALL child effects
let task = viewModel.sendViewEvent(.longOperation)
task.cancel()  // Propagates to all registered effect tasks

// Cancelling parent task cancels event processing
Task {
    await viewModel.sendViewEvent(.refresh).finish()
}
.cancel()  // Cancels refresh and its effects
```

**Edge Cases**:

1. **No Effects**: EventTask completes immediately after 10ms delay
2. **Context Unavailable**: Registration silently fails, EventTask returns empty (fire-and-forget)
3. **Effect Registered After Seal**: Assertion in debug, ignored in release
4. **Interactor Finishes Early**: Effects continue running, EventTask waits

### Observability

**Logging Strategy**:

```swift
@MainActor
final class ActionContext: Sendable {
    private let logger = Logger(subsystem: "UnoArchitecture", category: "ActionContext")

    func registerEffectTask(_ task: Task<Void, Never>) {
        guard !isSealed else {
            logger.warning("Attempted to register task after sealing")
            return
        }
        logger.debug("Registered effect task (\(effectTasks.count + 1) total)")
        effectTasks.append(task)
    }

    func seal() {
        isSealed = true
        logger.info("Sealed context with \(effectTasks.count) effect tasks")
    }
}
```

**Debugging Support**:

```swift
#if DEBUG
extension EventTask {
    /// Returns the number of underlying effect tasks being tracked.
    ///
    /// Useful for debugging to verify expected number of effects.
    public var effectTaskCount: Int {
        // Would require storing count in EventTask during creation
    }
}
#endif
```

**Instrumentation Points**:
1. Action sent (ViewModel)
2. Context created (ViewModel)
3. Effect registered (Interact)
4. Context sealed (ViewModel)
5. EventTask awaited (application code)
6. All effects completed (EventTask)

## Implementation Roadmap

### Phase 1: Core Infrastructure (MVP)

**Goal**: Basic EventTask support for `Interact` interactor.

**Tasks**:
- [ ] Create `ActionContext` with task registration
- [ ] Create `EventTask` public API
- [ ] Modify `ViewModel.sendViewEvent` to return `EventTask`
- [ ] Update `Interact` to register effect tasks
- [ ] Add basic tests for single-interactor scenarios

**Files**:
- `Sources/UnoArchitecture/Presentation/ViewModel/ActionContext.swift` (new)
- `Sources/UnoArchitecture/Presentation/ViewModel/EventTask.swift` (new)
- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift` (modify)
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/Interact.swift` (modify)
- `Tests/UnoArchitectureTests/PresentationTests/EventTaskTests.swift` (new)

**Testing**:
- Unit tests: ActionContext registration and sealing
- Integration tests: ViewModel + Interact with effects
- Edge case: No effects (immediate completion)

### Phase 2: Higher-Order Interactors

**Goal**: Verify task-local propagation through `Merge`, `When`, `MergeMany`.

**Tasks**:
- [ ] Add tests for `Merge` with effects
- [ ] Add tests for `When` with child effects
- [ ] Add tests for `MergeMany` with multiple effect-spawning children
- [ ] Document task-local propagation guarantees

**Files**:
- `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/EventTaskCompositionTests.swift` (new)

**Testing**:
- `Merge`: Both children spawn effects, all tracked
- `When`: Parent and child both spawn effects
- `MergeMany`: Multiple children with varying effect counts

### Phase 3: Testing Infrastructure

**Goal**: Enhance `InteractorTestHarness` to use `EventTask`.

**Tasks**:
- [ ] Update `InteractorTestHarness.send()` to return `EventTask`
- [ ] Add `sendSequentially` helper
- [ ] Add `finishWithTimeout` for tests
- [ ] Update example tests to use new API
- [ ] Migration guide for existing tests

**Files**:
- `Sources/UnoArchitecture/Testing/InteractorTestHarness.swift` (modify)
- `Tests/UnoArchitectureTests/TestingInfrastructureTests/InteractorTestHarnessTests.swift` (modify)
- `docs/migration/event-task-migration.md` (new)

**Testing**:
- Harness with async effects
- Sequential sends with effects
- Timeout behavior

### Phase 4: Documentation & Examples

**Goal**: Comprehensive documentation and real-world examples.

**Tasks**:
- [ ] Add DocC documentation for `EventTask`
- [ ] Add DocC documentation for `ActionContext`
- [ ] Update `ViewModel` documentation with examples
- [ ] Create SwiftUI `.refreshable` example
- [ ] Create cancellation example
- [ ] Update README with EventTask section

**Files**:
- `Sources/UnoArchitecture/Presentation/ViewModel/EventTask.swift` (DocC comments)
- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift` (DocC updates)
- `Examples/RefreshableExample/` (new)
- `README.md` (update)

### Phase 5: Optimization & Refinement

**Goal**: Production-ready reliability and performance.

**Tasks**:
- [ ] Make registration delay configurable (testing vs production)
- [ ] Add performance benchmarks
- [ ] Add logging and debugging utilities
- [ ] Add `effectTaskCount` debug property
- [ ] Consider deprecation warnings for old test patterns

**Files**:
- `Sources/UnoArchitecture/Presentation/ViewModel/ActionContext.swift` (logging)
- `Sources/UnoArchitecture/Presentation/ViewModel/EventTask.swift` (debug utilities)
- `Tests/UnoArchitectureTests/PerformanceTests/EventTaskPerformanceTests.swift` (new)

### Migration Strategy

**Backward Compatibility**:
- `sendViewEvent` return value is `@discardableResult`, so old code compiles without changes
- Fire-and-forget pattern remains the default: `viewModel.sendViewEvent(.tap)`
- Interactors without context registration work normally (effects run, just not tracked)

**Migration Path**:

1. **Phase 1 Release**: Introduce EventTask, document fire-and-forget still works
2. **Phase 2-3 Release**: Enhance testing utilities, encourage adoption in tests
3. **Phase 4 Release**: Promote in documentation and examples
4. **Future**: Consider linting rule to detect arbitrary `Task.sleep` in tests

**No Breaking Changes**:
- Interactor protocol unchanged
- Existing interactors continue working
- Old tests continue passing
- Gradual adoption possible

## Implementation Guidelines

### File Structure

```
Sources/UnoArchitecture/
├── Presentation/
│   └── ViewModel/
│       ├── ActionContext.swift         # NEW: Task tracking
│       ├── EventTask.swift             # NEW: Public API
│       ├── ViewModel.swift             # MODIFIED: Return EventTask
│       └── ViewModelBinding.swift      # UNCHANGED
├── Domain/
│   └── Interactor/
│       └── Interactors/
│           ├── Interact.swift          # MODIFIED: Register tasks
│           ├── Merge.swift             # UNCHANGED: Task-local propagates
│           ├── When.swift              # UNCHANGED: Task-local propagates
│           └── MergeMany.swift         # UNCHANGED: Task-local propagates
└── Testing/
    └── InteractorTestHarness.swift     # MODIFIED: Return EventTask

Tests/UnoArchitectureTests/
├── PresentationTests/
│   ├── EventTaskTests.swift            # NEW: Core tests
│   └── ViewModelEventTaskTests.swift   # NEW: Integration tests
└── DomainTests/
    └── InteractorTests/
        └── EventTaskCompositionTests.swift  # NEW: Composition tests
```

### Key Patterns

**Pattern 1: Task-Local Propagation**
```swift
// Task-local values automatically propagate through child tasks
Task {  // Outer task has ActionContext.current = ctx
    await childWork()  // Child inherits ctx automatically
}
```

**Pattern 2: Optional Registration**
```swift
// Graceful degradation when context unavailable
ActionContext.current?.registerEffectTask(effectTask)
// Works with or without context
```

**Pattern 3: Sealed Context**
```swift
// Prevent late registrations
context.seal()  // After this, registration fails
```

**Pattern 4: Composite Task**
```swift
// Await all effects in parallel
await withTaskGroup(of: Void.self) { group in
    for task in tasks {
        group.addTask { await task.value }
    }
}
```

### Code Examples

**Example 1: SwiftUI Refreshable**
```swift
struct FeedView: View {
    @StateObject var viewModel: FeedViewModel

    var body: some View {
        List(viewModel.items) { item in
            ItemRow(item: item)
        }
        .refreshable {
            await viewModel.sendViewEvent(.refresh).finish()
        }
    }
}
```

**Example 2: Cancellable Long Operation**
```swift
struct ProcessingView: View {
    @StateObject var viewModel: ProcessingViewModel
    @State private var currentTask: EventTask?

    var body: some View {
        VStack {
            Button("Start Processing") {
                currentTask = viewModel.sendViewEvent(.startProcessing)
            }

            Button("Cancel") {
                currentTask?.cancel()
            }
            .disabled(currentTask == nil)
        }
    }
}
```

**Example 3: Sequential Actions in Tests**
```swift
@Test
func testSequentialFlow() async throws {
    let harness = await InteractorTestHarness(FlowInteractor())

    // Each action completes before next starts
    await harness.send(.initialize).finish()
    await harness.send(.fetchData).finish()
    await harness.send(.processData).finish()

    try await harness.assertStates([
        .idle,
        .initialized,
        .loading,
        .loaded(data),
        .processing,
        .complete
    ])
}
```

**Example 4: Custom Interactor Opt-In**
```swift
struct CustomInteractor: Interactor {
    func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
        AsyncStream { continuation in
            Task { @MainActor in
                for await action in upstream {
                    // Custom async work
                    let effectTask = Task {
                        await performCustomWork()
                    }

                    // Opt-in to EventTask tracking
                    ActionContext.current?.registerEffectTask(effectTask)

                    continuation.yield(newState)
                }
            }
        }
    }
}
```

## Open Questions

1. **10ms Delay**: Is 10ms the right balance? Should it be configurable?
   - Recommendation: Start with 10ms, make configurable if issues arise

2. **Long-Running Effects**: Should there be a maximum timeout for EventTask?
   - Recommendation: No built-in timeout, let application code decide

3. **Effect Completion Order**: Should EventTask wait for effects in order or in parallel?
   - Recommendation: Parallel (current design with `withTaskGroup`)

4. **Context Unavailable**: Should this log a warning or be completely silent?
   - Recommendation: Silent in release, assertion in debug

5. **InteractorTestHarness**: Should `send()` return EventTask or have separate `sendAwaitable()`?
   - Recommendation: Same method, `@discardableResult` for backward compat

## References

### TCA's StoreTask
- [TCA Store.swift](https://github.com/pointfreeco/swift-composable-architecture/blob/main/Sources/ComposableArchitecture/Store.swift)
- [TCA Effects](https://pointfreeco.github.io/swift-composable-architecture/main/documentation/composablearchitecture/effects)

### Swift Concurrency
- [Task-Local Values](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Task-Local-Values)
- [Structured Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Structured-Concurrency)

### Related Uno Documentation
- Current ViewModel implementation: `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift`
- Current Interact implementation: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Interact.swift`
- Testing utilities: `Sources/UnoArchitecture/Testing/InteractorTestHarness.swift`

### Similar Patterns
- Martin Fowler: [Command Pattern](https://refactoring.guru/design-patterns/command) - Encapsulating requests as objects
- Reactive Extensions: Observable completion semantics

---

**Document Status**: DRAFT
**Next Steps**: Review with team, validate 10ms delay assumption, prototype Phase 1

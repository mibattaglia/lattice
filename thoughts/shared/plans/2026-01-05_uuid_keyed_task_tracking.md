# UUID-Keyed Task Tracking Design

## Status: Implemented

## Overview

Migrate from array-based effect task tracking to UUID-keyed dictionary tracking in ViewModel. This enables per-effect cancellation, O(1) task removal, lifecycle visibility, and matches TCA's proven pattern.

## Current State Analysis

### Array-Based Implementation (Current)

The ViewModel currently uses a simple array to track spawned tasks:

```swift
// ViewModel.swift:102
private var effectTasks: [Task<Void, Never>] = []
```

**Current spawning flow** (`sendViewEvent` at ViewModel.swift:180-202):
```swift
@discardableResult
public func sendViewEvent(_ event: Action) -> EventTask {
    let originalDomainState = domainState
    let emission = interactor.interact(state: &domainState, action: event)
    if !areStatesEqual(originalDomainState, domainState) {
        viewStateReducer.reduce(domainState, into: &viewState)
    }

    let tasks = spawnTasks(from: emission)
    effectTasks.append(contentsOf: tasks)  // Array accumulation

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
```

**Current cleanup** (ViewModel.swift:249-251):
```swift
deinit {
    effectTasks.forEach { $0.cancel() }
}
```

### Problems with Array-Based Tracking

1. **No per-effect cancellation**: Cannot cancel a specific effect by identifier
2. **Memory accumulation**: Tasks are only appended, never removed until deinit
3. **No lifecycle visibility**: Cannot query active effect count or inspect specific effects
4. **O(n) operations**: Would require linear search to find/remove specific tasks
5. **No correlation**: Cannot associate tasks with the actions that spawned them

### InteractorTestHarness Also Affected

The test harness mirrors the same array-based pattern at `InteractorTestHarness.swift:68`:
```swift
private var effectTasks: [Task<Void, Never>] = []
```

---

## Proposed Design: UUID-Keyed Dictionary

### TCA Reference Implementation

TCA uses a UUID-keyed dictionary for effect tracking in `RootCore`:

```swift
var effectCancellables: [UUID: AnyCancellable] = [:]

func _send(_ action: Root.Action) -> Task<Void, Never>? {
    let tasks = LockIsolated<[Task<Void, Never>]>([])

    // For each effect...
    let uuid = UUID()
    let task = Task { @MainActor [weak self] in
        await operation(Send { ... })
        self?.effectCancellables[uuid] = nil  // Cleanup after await
    }
    self.effectCancellables[uuid] = AnyCancellable { task.cancel() }

    // Composite task with cancellation handler
    return Task { @MainActor in
        await withTaskCancellationHandler {
            for task in tasks { await task.value }
        } onCancel: {
            for task in tasks { task.cancel() }
        }
    }
}
```

Key characteristics:
- Stores `AnyCancellable` wrappers, not Tasks directly
- Cleanup is explicit code after `await`, NOT in a `defer`
- Uses `withTaskCancellationHandler` for structured cancellation
- `LockIsolated` for thread-safe task collection

### Our Design: UUID-Keyed Tasks with Structured Cancellation

#### Effect Storage

```swift
private var effectTasks: [UUID: Task<Void, Never>] = [:]
```

Store Tasks directly (simpler than AnyCancellable wrappers since we're pure async/await).

#### Task Spawning with UUID Tracking

```swift
private func spawnTasks(from emission: Emission<Action>) -> [UUID: Task<Void, Never>] {
    switch emission.kind {
    case .none:
        return [:]

    case .action(let action):
        let innerEmission = interactor.interact(state: &domainState, action: action)
        viewStateReducer.reduce(domainState, into: &viewState)
        return spawnTasks(from: innerEmission)

    case .perform(let work):
        let uuid = UUID()
        let task = Task { [weak self] in
            guard let action = await work() else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                let emission = self.interactor.interact(state: &self.domainState, action: action)
                self.viewStateReducer.reduce(self.domainState, into: &self.viewState)
                let newTasks = self.spawnTasks(from: emission)
                self.effectTasks.merge(newTasks) { _, new in new }
            }
        }
        return [uuid: task]

    case .observe(let stream):
        let uuid = UUID()
        let task = Task { [weak self] in
            for await action in await stream() {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let self else { return }
                    let emission = self.interactor.interact(state: &self.domainState, action: action)
                    self.viewStateReducer.reduce(self.domainState, into: &self.viewState)
                    let newTasks = self.spawnTasks(from: emission)
                    self.effectTasks.merge(newTasks) { _, new in new }
                }
            }
        }
        return [uuid: task]

    case .merge(let emissions):
        return emissions.reduce(into: [:]) { result, emission in
            result.merge(spawnTasks(from: emission)) { _, new in new }
        }
    }
}
```

#### sendViewEvent with Structured Cancellation

```swift
@discardableResult
public func sendViewEvent(_ event: Action) -> EventTask {
    let originalDomainState = domainState
    let emission = interactor.interact(state: &domainState, action: event)
    if !areStatesEqual(originalDomainState, domainState) {
        viewStateReducer.reduce(domainState, into: &viewState)
    }

    let spawnedTasks = spawnTasks(from: emission)
    let spawnedUUIDs = Set(spawnedTasks.keys)
    effectTasks.merge(spawnedTasks) { _, new in new }

    guard !spawnedTasks.isEmpty else {
        return EventTask(rawValue: nil)
    }

    let taskList = Array(spawnedTasks.values)
    let compositeTask = Task { [weak self] in
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for task in taskList {
                    group.addTask { await task.value }
                }
            }
        } onCancel: {
            for task in taskList {
                task.cancel()
            }
        }
        // Cleanup after all tasks from this event complete
        for uuid in spawnedUUIDs {
            self?.effectTasks[uuid] = nil
        }
    }

    return EventTask(rawValue: compositeTask)
}
```

#### Deinit Cleanup

```swift
deinit {
    for task in effectTasks.values {
        task.cancel()
    }
}
```

---

## Design Decisions

### Why UUID-Keyed Dictionary (not Array)?

1. **Per-effect tracking**: Can identify and potentially cancel individual effects
2. **Clean removal**: O(1) removal by UUID vs O(n) array search
3. **Lifecycle visibility**: `effectTasks.count` shows active effect count
4. **Matches TCA pattern**: Proven approach in production

### Why Cleanup at Composite Task Level (not `defer`)?

We considered using `defer` inside each spawned task:

```swift
let task = Task { [weak self] in
    defer {
        Task { @MainActor [weak self] in
            self?.effectTasks[uuid] = nil
        }
    }
    await work(dynamicState, send)
}
```

Issues with `defer`:
- Requires hopping back to MainActor from potentially non-MainActor context
- Spawns additional Task just for cleanup
- More complex control flow

Cleanup at composite task level is simpler:
- All effects from one event cleaned up together
- Single MainActor hop after all effects complete
- Matches the EventTask's semantic boundary

### Why `withTaskCancellationHandler`?

Essential for proper cancellation propagation:

```swift
await withTaskCancellationHandler {
    // Await child tasks
} onCancel: {
    // Cancel all children when parent cancelled
}
```

When `eventTask.cancel()` is called:
1. The composite task receives cancellation
2. `onCancel` fires, cancelling all child effect tasks
3. Child tasks cooperatively exit (via `Task.isCancelled` checks or throwing)
4. `withTaskGroup` completes
5. Cleanup runs

Without this, `eventTask.cancel()` would only cancel the composite task, leaving child effects orphaned.

### Why Store Tasks Directly (not AnyCancellable)?

TCA stores `AnyCancellable` because it integrates with Combine publishers. Our effects are pure async/await, so storing `Task` directly is:
- Simpler (no wrapper allocation)
- More direct (call `task.cancel()` directly)
- Type-safe (`Task<Void, Never>` vs type-erased `AnyCancellable`)

---

## Comparison Summary

| Aspect | Current (Array) | Proposed (UUID Dictionary) | TCA |
|--------|-----------------|---------------------------|-----|
| Storage Type | `[Task<Void, Never>]` | `[UUID: Task<Void, Never>]` | `[UUID: AnyCancellable]` |
| Task Removal | Never (until deinit) | After completion | After completion |
| Cancellation | Bulk only | Per-effect possible | Per-effect possible |
| Cleanup Timing | deinit only | After event effects complete | After each effect's await |
| Memory Growth | Unbounded | Bounded by active effects | Bounded by active effects |

---

## Optional: Debug API

Consider exposing for testing/debugging:

```swift
#if DEBUG
public var activeEffectCount: Int {
    effectTasks.count
}
#endif
```

---

## Implementation Plan

### Phase 1: ViewModel Migration

1. Change `effectTasks` type from `[Task<Void, Never>]` to `[UUID: Task<Void, Never>]`
2. Update `spawnTasks(from:)` to return `[UUID: Task<Void, Never>]`
3. Update `sendViewEvent(_:)` to:
   - Use `merge` instead of `append`
   - Add `withTaskCancellationHandler`
   - Add cleanup after composite task completion
4. Update deinit to iterate `.values`

### Phase 2: InteractorTestHarness Migration

Apply same changes to `InteractorTestHarness.swift` for consistency.

### Phase 3: Testing

1. Verify existing tests pass
2. Add tests for:
   - Task cleanup after completion
   - `activeEffectCount` accuracy (if debug API added)
   - Cancellation propagation via `withTaskCancellationHandler`

---

## Files to Modify

- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift`
- `Sources/UnoArchitecture/Testing/InteractorTestHarness.swift`

---

## References

- Original design: `thoughts/shared/plans/2025-01-03_sync_interactor_api.md` (Addendum: Effect Task Tracking Design)
- TCA Core implementation: `/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Core.swift`

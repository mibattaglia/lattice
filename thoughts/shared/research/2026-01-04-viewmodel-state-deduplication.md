---
date: 2026-01-04T16:10:54Z
researcher: michaelbattaglia
git_commit: c8f99a625cc988367068af80045762567b5388f5
branch: mibattag/make-sync
repository: mibattaglia/swift-uno-architecture
topic: "ViewModel state update flow and deduplication opportunities"
tags: [research, codebase, viewmodel, state-deduplication, send]
status: complete
last_updated: 2026-01-04
last_updated_by: michaelbattaglia
---

# Research: ViewModel State Update Flow and Deduplication Opportunities

**Date**: 2026-01-04T16:10:54Z
**Researcher**: michaelbattaglia
**Git Commit**: c8f99a625cc988367068af80045762567b5388f5
**Branch**: mibattag/make-sync
**Repository**: mibattaglia/swift-uno-architecture

## Research Question

Research the ViewModel implementation to understand how state updates flow through the system and identify where state deduplication using an `areStatesEqual` comparison could be added, similar to what was implemented in `InteractorTestHarness`.

## Summary

The ViewModel has two distinct state update paths:

1. **Synchronous path** - In `sendViewEvent()`, after `interactor.interact()` mutates `domainState`
2. **Asynchronous path** - In `makeSend()`, when effects emit new states via the `Send` callback

The `Send` type in `Internal/Send.swift` is the central point for async state emissions. Adding deduplication here would affect all async state updates from effects (`.perform` and `.observe` emissions).

## Detailed Findings

### State Update Flow in ViewModel

#### Path 1: Synchronous Updates (`ViewModel.swift:174-176`)

```swift
public func sendViewEvent(_ event: Action) -> EventTask {
    let emission = interactor.interact(state: &domainState, action: event)
    viewStateReducer.reduce(domainState, into: &viewState)
    // ...
}
```

The interactor mutates `domainState` via `inout`, then the reducer immediately transforms it to `viewState`. This happens synchronously on every action.

#### Path 2: Async Updates via Send (`ViewModel.swift:231-236`)

```swift
private func makeSend() -> Send<DomainState> {
    Send { [weak self] newState in
        guard let self else { return }
        self.domainState = newState
        self.viewStateReducer.reduce(newState, into: &self.viewState)
    }
}
```

Effects call `send(newState)` to emit state updates. The `Send` closure updates `domainState` and runs the reducer.

### The Send Type (`Internal/Send.swift:32-51`)

```swift
@MainActor
public struct Send<State: Sendable>: Sendable {
    private let yield: @MainActor (State) -> Void

    init(_ yield: @escaping @MainActor (State) -> Void) {
        self.yield = yield
    }

    public func callAsFunction(_ state: State) {
        guard !Task.isCancelled else { return }
        yield(state)
    }
}
```

Currently, `Send` only checks for task cancellation before yielding. This is the location where state deduplication could be added for async updates.

### Comparison: InteractorTestHarness Implementation

In `InteractorTestHarness.swift:93-99`, the `appendToHistory()` function dedupes states:

```swift
private func appendToHistory() {
    guard let lastState = stateHistory.last else {
        stateHistory.append(state)
        return
    }
    guard !areStatesEqual(lastState, state) else { return }
    stateHistory.append(state)
}
```

This pattern compares the new state against the previous state and skips if equal.

### Candidate Locations for Deduplication

#### Option A: Inside `Send.callAsFunction` (`Send.swift:47-50`)

Add comparison logic directly in `Send`:

```swift
public func callAsFunction(_ state: State) {
    guard !Task.isCancelled else { return }
    // Add: guard !areStatesEqual(previousState, state) else { return }
    yield(state)
}
```

**Consideration**: `Send` would need access to the previous state and a comparison function. Currently it only holds a `yield` closure.

#### Option B: Inside the yield closure in `makeSend()` (`ViewModel.swift:232-235`)

Add comparison in the closure passed to `Send`:

```swift
Send { [weak self] newState in
    guard let self else { return }
    // Add: guard !areStatesEqual(self.domainState, newState) else { return }
    self.domainState = newState
    self.viewStateReducer.reduce(newState, into: &self.viewState)
}
```

**Consideration**: This keeps deduplication logic in ViewModel where state is accessible.

#### Option C: In `sendViewEvent()` for synchronous path (`ViewModel.swift:174-176`)

Extract mutation to a local var to enable comparison:

```swift
public func sendViewEvent(_ event: Action) -> EventTask {
    var newState = domainState  // Copy before mutation
    let emission = interactor.interact(state: &newState, action: event)

    // Now we can compare: domainState = old, newState = new
    guard !areStatesEqual(domainState, newState) else {
        // Skip reducer, still spawn effects
        let tasks = spawnTasks(from: emission)
        // ...
    }

    domainState = newState
    viewStateReducer.reduce(domainState, into: &viewState)
    // ...
}
```

**Tradeoff**: One extra state copy per action, but enables comparison before updating.

### ViewState Observation Mechanism

The ViewModel uses `ObservationRegistrar` for view updates (`ViewModel.swift:149-162`):

```swift
public private(set) var viewState: ViewState {
    get {
        _$observationRegistrar.access(self, keyPath: \.viewState)
        return _viewState
    }
    set {
        if _viewState._$id == newValue._$id {
            _viewState = newValue
        } else {
            _$observationRegistrar.withMutation(of: self, keyPath: \.viewState) {
                _viewState = newValue
            }
        }
    }
}
```

The setter already has optimization: if `_$id` matches, it skips the mutation notification. This is identity-based deduplication at the view state level.

## Code References

- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift:174-176` - Synchronous state update in `sendViewEvent()`
- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift:231-236` - `makeSend()` factory creates async update closure
- `Sources/UnoArchitecture/Internal/Send.swift:47-50` - `Send.callAsFunction` yields state
- `Sources/UnoArchitecture/Testing/InteractorTestHarness.swift:93-99` - `appendToHistory()` deduplication implementation
- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift:149-162` - ViewState setter with `_$id` optimization

## Architecture Documentation

### Current State Flow

```
Action → Interactor.interact(inout state) → Emission
                    ↓
            domainState mutated
                    ↓
            viewStateReducer.reduce()
                    ↓
            viewState updated
                    ↓
            ObservationRegistrar notifies (if _$id differs)
```

### Async Effect Flow

```
.perform/.observe spawned → Task executes
                                ↓
                          send(newState) called
                                ↓
                          Task.isCancelled check
                                ↓
                          yield(state) → domainState = newState
                                ↓
                          viewStateReducer.reduce()
```

### Deduplication Points

1. **Domain State Level** - Before `domainState = newState` in `makeSend()` closure
2. **View State Level** - Already exists via `_$id` comparison in viewState setter
3. **Send Level** - Would require restructuring `Send` to hold previous state reference

## Open Questions

1. Should deduplication happen at domain state level, view state level, or both?
2. How should `areStatesEqual` be provided to the ViewModel? (generic parameter, initializer argument, protocol requirement?)
3. Should the synchronous path in `sendViewEvent()` also dedupe, or only async effects?

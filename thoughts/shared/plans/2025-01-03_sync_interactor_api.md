# Synchronous Interactor API Implementation Plan

## Overview

Transform the Uno Architecture's core Interactor protocol from asynchronous stream-based (`AsyncStream<Action> -> AsyncStream<State>`) to synchronous function-based (`(inout State, Action) -> Emission<State>`). This enables ViewModel to immediately capture effect tasks when processing actions, making `sendViewEvent` returnable as `EventTask` without correlation infrastructure.

## Current State Analysis

### Existing Architecture

The current implementation uses AsyncStream throughout:

- **Interactor Protocol** (`Interactor.swift:53-69`): Defines `interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState>`
- **Interact Primitive** (`Interact.swift:63-146`): Creates AsyncStream, uses StateBox internally, spawns effect Tasks
- **ViewModel** (`ViewModel.swift:82-157`): Creates action stream with continuation, subscribes to interactor stream
- **Higher-Order Interactors**: Merge/MergeMany create child streams per action, When uses AsyncChannel for routing

### Key Problems with Current Approach

1. **Asynchronous Gap**: By the time handler runs and spawns effects, `sendViewEvent` has returned
2. **Complex State Management**: StateBox hidden inside stream closure
3. **Testing Complexity**: Must await arbitrary delays for effects to spawn
4. **Performance Overhead**: AsyncStream continuation management, action queueing

## Desired End State

After implementation:

1. `Interactor` protocol has synchronous `interact(state: inout DomainState, action: Action) -> Emission<DomainState>` method
2. `Interactor` protocol requires `var initialValue: DomainState { get }` for eager ViewModel initialization
3. `Emission` supports `.merge([Emission])` case for composition
4. `ViewModel.sendViewEvent(_:)` returns `EventTask` immediately with spawned effects
5. No DomainBox, no StateBox - direct state storage in ViewModel
6. Higher-order interactors use direct function calls and emission merging
7. `InteractorTestHarness` supports sync testing with explicit effect awaiting

### Verification Commands

```bash
# All tests pass
swift test

# Build succeeds
swift build
```

## What We're NOT Doing

- Backward compatibility with async stream API (library is alpha)
- Supporting both sync and async interactor protocols simultaneously
- Changing the Emission effect closure signatures (`.perform`, `.observe`)
- Modifying DynamicState or Send types
- Changing the @Interactor macro behavior (handlers already use inout)
- Adding any correlation infrastructure (ActionContext, task-locals)

## Implementation Approach

Transform bottom-up: protocol → primitives → higher-order → ViewModel → testing. Each phase is independently testable, minimizing risk.

---

## Phase 1: Core Protocol and Emission Changes

### Overview

Update the Interactor protocol to synchronous API and add `.merge` case to Emission.

### Changes Required:

#### 1. Interactor Protocol

**File**: `Sources/UnoArchitecture/Domain/Interactor.swift`

**Changes**:
- Add `var initialValue: DomainState { get }` requirement
- Replace `interact(_ upstream:)` with `interact(state: inout DomainState, action: Action) -> Emission<DomainState>`
- Update default implementations
- Update AnyInteractor to capture initialValue and call sync method

```swift
public protocol Interactor<DomainState, Action> {
    associatedtype DomainState: Sendable
    associatedtype Action: Sendable
    associatedtype Body: Interactor

    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    /// The initial domain state for this interactor.
    var initialValue: DomainState { get }

    /// Processes an action by mutating state and returning an emission.
    func interact(state: inout DomainState, action: Action) -> Emission<DomainState>
}

extension Interactor where Body: Interactor<DomainState, Action> {
    public var initialValue: DomainState {
        body.initialValue
    }

    public func interact(state: inout DomainState, action: Action) -> Emission<DomainState> {
        body.interact(state: &state, action: action)
    }
}

extension Interactor where Body.DomainState == Never {
    public var initialValue: DomainState {
        fatalError("'\(Self.self)' must implement 'initialValue' when providing a custom 'interact(state:action:)' implementation.")
    }
}
```

**AnyInteractor update**:
```swift
public struct AnyInteractor<State: Sendable, Action: Sendable>: Interactor, Sendable {
    private let _initialValue: State
    private let interactFunc: @Sendable (inout State, Action) -> Emission<State>

    public init<I: Interactor & Sendable>(_ base: I) where I.DomainState == State, I.Action == Action {
        self._initialValue = base.initialValue
        self.interactFunc = { state, action in base.interact(state: &state, action: action) }
    }

    public var initialValue: State { _initialValue }
    public var body: some Interactor<State, Action> { self }

    public func interact(state: inout State, action: Action) -> Emission<State> {
        interactFunc(&state, action)
    }
}
```

#### 2. Emission Type

**File**: `Sources/UnoArchitecture/Domain/Emission.swift`

**Changes**: Add `.merge` case for composing multiple emissions

```swift
public struct Emission<State: Sendable>: Sendable {
    public enum Kind: Sendable {
        case state
        case perform(work: @Sendable (DynamicState<State>, Send<State>) async -> Void)
        case observe(stream: @Sendable (DynamicState<State>, Send<State>) async -> Void)
        case merge([Emission<State>])
    }

    let kind: Kind

    public static var state: Emission { Emission(kind: .state) }

    public static func perform(
        _ work: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .perform(work: work))
    }

    public static func observe(
        _ stream: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .observe(stream: stream))
    }

    public static func merge(_ emissions: [Emission<State>]) -> Emission {
        Emission(kind: .merge(emissions))
    }

    public func merging(with other: Emission<State>) -> Emission<State> {
        .merge([self, other])
    }
}
```

#### 3. Delete StateBox

**File**: `Sources/UnoArchitecture/Internal/StateBox.swift`

**Changes**: Delete entire file (no longer needed - ViewModel owns state directly)

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build` (expected: fails until Interact/ViewModel updated)
- [ ] Protocol changes compile correctly

#### Manual Verification:
- [ ] Protocol documentation is accurate
- [ ] AnyInteractor captures initialValue at initialization

---

## Phase 2: Interact Primitive Rewrite

### Overview

Simplify Interact to synchronous handler that exposes initialValue.

### Changes Required:

#### 1. Interact Implementation

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Interact.swift`

**Changes**: Remove AsyncStream, StateBox usage. Expose initialValue. Just delegate to handler.

```swift
import Foundation

public struct Interact<State: Sendable, Action: Sendable>: Interactor, @unchecked Sendable {
    public typealias Handler = @MainActor (inout State, Action) -> Emission<State>

    private let _initialValue: State
    private let handler: Handler

    public init(initialValue: State, handler: @escaping Handler) {
        self._initialValue = initialValue
        self.handler = handler
    }

    public var initialValue: State { _initialValue }

    public var body: some Interactor<State, Action> { self }

    public func interact(state: inout State, action: Action) -> Emission<State> {
        handler(&state, action)
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build` (expected: fails until ViewModel/higher-order updated)

#### Manual Verification:
- [ ] Interact implementation is ~30 lines (down from ~145)
- [ ] Handler signature unchanged from current

---

## Phase 3: Higher-Order Interactors Rewrite

### Overview

Rewrite Merge, MergeMany, and When to use synchronous calls and emission merging.

### Changes Required:

#### 1. Merge Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Merge.swift`

**Changes**: Replace AsyncStream with direct function calls and emission merging

```swift
extension Interactors {
    public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor, @unchecked Sendable
    where I0.DomainState: Sendable, I0.Action: Sendable {
        private let i0: I0
        private let i1: I1

        public init(_ i0: I0, _ i1: I1) {
            self.i0 = i0
            self.i1 = i1
        }

        public var initialValue: I0.DomainState {
            i0.initialValue
        }

        public var body: some Interactor<I0.DomainState, I0.Action> { self }

        public func interact(state: inout I0.DomainState, action: I0.Action) -> Emission<I0.DomainState> {
            let emission0 = i0.interact(state: &state, action: action)
            let emission1 = i1.interact(state: &state, action: action)
            return .merge([emission0, emission1])
        }
    }
}
```

#### 2. MergeMany Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/MergeMany.swift`

**Changes**: Replace AsyncStream with direct iteration and emission merging

```swift
extension Interactors {
    public struct MergeMany<Element: Interactor>: Interactor, @unchecked Sendable
    where Element.DomainState: Sendable, Element.Action: Sendable {
        private let interactors: [Element]

        public init(interactors: [Element]) {
            self.interactors = interactors
        }

        public var initialValue: Element.DomainState {
            guard let first = interactors.first else {
                fatalError("MergeMany requires at least one interactor")
            }
            return first.initialValue
        }

        public var body: some Interactor<Element.DomainState, Element.Action> { self }

        public func interact(state: inout Element.DomainState, action: Element.Action) -> Emission<Element.DomainState> {
            let emissions = interactors.map { interactor in
                interactor.interact(state: &state, action: action)
            }
            return .merge(emissions)
        }
    }
}
```

#### 3. When Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`

**Changes**: Replace AsyncChannel routing with direct function calls

```swift
import CasePaths
import Foundation

extension Interactor where Self: Sendable {
    public func when<ChildState, ChildAction, Child: Interactor & Sendable>(
        stateIs toChildState: WritableKeyPath<DomainState, ChildState>,
        actionIs toChildAction: CaseKeyPath<Action, ChildAction>,
        stateAction toStateAction: CaseKeyPath<Action, ChildState>,
        @InteractorBuilder<ChildState, ChildAction> run child: () -> Child
    ) -> Interactors.When<Self, Child>
    where Child.DomainState == ChildState, Child.Action == ChildAction {
        Interactors.When(
            parent: self,
            toChildState: .keyPath(toChildState),
            toChildAction: AnyCasePath(toChildAction),
            toStateAction: AnyCasePath(toStateAction),
            child: child()
        )
    }

    public func when<ChildState, ChildAction, Child: Interactor & Sendable>(
        stateIs toChildState: CaseKeyPath<DomainState, ChildState>,
        actionIs toChildAction: CaseKeyPath<Action, ChildAction>,
        stateAction toStateAction: CaseKeyPath<Action, ChildState>,
        @InteractorBuilder<ChildState, ChildAction> run child: () -> Child
    ) -> Interactors.When<Self, Child>
    where Child.DomainState == ChildState, Child.Action == ChildAction {
        Interactors.When(
            parent: self,
            toChildState: .casePath(AnyCasePath(toChildState)),
            toChildAction: AnyCasePath(toChildAction),
            toStateAction: AnyCasePath(toStateAction),
            child: child()
        )
    }
}

extension Interactors {
    public struct When<Parent: Interactor & Sendable, Child: Interactor & Sendable>: Interactor, Sendable
    where
        Parent.DomainState: Sendable, Parent.Action: Sendable,
        Child.DomainState: Sendable, Child.Action: Sendable
    {
        public typealias DomainState = Parent.DomainState
        public typealias Action = Parent.Action

        enum StatePath: @unchecked Sendable {
            case keyPath(WritableKeyPath<Parent.DomainState, Child.DomainState>)
            case casePath(AnyCasePath<Parent.DomainState, Child.DomainState>)
        }

        let parent: Parent
        let toChildState: StatePath
        let toChildAction: AnyCasePath<Parent.Action, Child.Action>
        let toStateAction: AnyCasePath<Parent.Action, Child.DomainState>
        let child: Child

        public var initialValue: DomainState {
            parent.initialValue
        }

        public var body: some Interactor<DomainState, Action> { self }

        public func interact(state: inout DomainState, action: Action) -> Emission<DomainState> {
            if let childAction = toChildAction.extract(from: action) {
                switch toChildState {
                case .keyPath(let kp):
                    var childState = state[keyPath: kp]
                    let childEmission = child.interact(state: &childState, action: childAction)
                    state[keyPath: kp] = childState
                    return childEmission

                case .casePath(let cp):
                    guard var childState = cp.extract(from: state) else {
                        return parent.interact(state: &state, action: action)
                    }
                    let childEmission = child.interact(state: &childState, action: childAction)
                    let stateAction = toStateAction.embed(childState)
                    let parentEmission = parent.interact(state: &state, action: stateAction)
                    return .merge([childEmission, parentEmission])
                }
            } else {
                return parent.interact(state: &state, action: action)
            }
        }
    }
}
```

#### 4. Remove AsyncChannel Extension

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`

**Changes**: Delete the `AsyncChannel.eraseToAsyncStream()` extension (no longer needed)

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build` (expected: fails until ViewModel updated)

#### Manual Verification:
- [ ] No AsyncStream/AsyncChannel usage in higher-order interactors
- [ ] Merge uses first child's initialValue
- [ ] When uses parent's initialValue

---

## Phase 4: EventTask Implementation

### Overview

Create the EventTask type for representing spawned effect tasks.

### Changes Required:

#### 1. Create EventTask

**File**: `Sources/UnoArchitecture/Presentation/ViewModel/EventTask.swift` (new file)

**Changes**: Create new file with EventTask implementation

```swift
import Foundation

/// A handle to the effects spawned by a single `sendViewEvent` call.
///
/// Use `EventTask` to await completion of effects or cancel them.
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
/// await viewModel.sendViewEvent(.fetch).finish()
/// ```
///
/// Cancel:
/// ```swift
/// let task = viewModel.sendViewEvent(.longOperation)
/// task.cancel()
/// ```
public struct EventTask: Sendable {
    internal let rawValue: Task<Void, Never>?

    internal init(rawValue: Task<Void, Never>?) {
        self.rawValue = rawValue
    }

    /// Cancels all effects spawned by this event.
    public func cancel() {
        rawValue?.cancel()
    }

    /// Awaits completion of all effects spawned by this event.
    @discardableResult
    public func finish() async {
        await rawValue?.value
    }

    /// Whether this event's effects have been cancelled.
    public var isCancelled: Bool {
        rawValue?.isCancelled ?? false
    }

    /// Whether this event spawned any effects.
    public var hasEffects: Bool {
        rawValue != nil
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build`

#### Manual Verification:
- [ ] EventTask API is clear and intuitive
- [ ] Documentation covers all use cases

---

## Phase 5: ViewModel Rewrite

### Overview

Rewrite ViewModel to use synchronous processing, spawn tasks from emissions, and return EventTask.

### Changes Required:

#### 1. ViewModel Implementation

**File**: `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift`

**Changes**:
- Remove AsyncStream, continuation
- Initialize domainState eagerly from interactor.initialValue
- Add spawnTasks(from:) method
- Update sendViewEvent to return EventTask
- Add effectTasks tracking for lifecycle management

```swift
import Observation
import SwiftUI

@MainActor
protocol _ViewModel {
    associatedtype ViewState: ObservableState
    var viewState: ViewState { get }
}

@dynamicMemberLookup
@MainActor
public final class ViewModel<Action, DomainState, ViewState>: Observable, _ViewModel
where Action: Sendable, DomainState: Sendable, ViewState: ObservableState {
    private var _viewState: ViewState
    private var domainState: DomainState
    private var effectTasks: [Task<Void, Never>] = []

    private let interactor: AnyInteractor<DomainState, Action>
    private let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>

    private let _$observationRegistrar = ObservationRegistrar()

    public init(
        initialValue: @autoclosure () -> ViewState,
        _ interactor: AnyInteractor<DomainState, Action>,
        _ viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    ) {
        self.interactor = interactor
        self.viewStateReducer = viewStateReducer
        self.domainState = interactor.initialValue
        self._viewState = initialValue()
    }

    public init(
        _ initialValue: @autoclosure () -> ViewState,
        _ interactor: AnyInteractor<ViewState, Action>
    ) where DomainState == ViewState {
        self.interactor = interactor
        self.viewStateReducer = BuildViewState<ViewState, ViewState> { domainState, viewState in
            viewState = domainState
        }.eraseToAnyViewStateReducer()
        self.domainState = interactor.initialValue
        self._viewState = initialValue()
    }

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

    public subscript<Value>(dynamicMember keyPath: KeyPath<ViewState, Value>) -> Value {
        self.viewState[keyPath: keyPath]
    }

    @discardableResult
    public func sendViewEvent(_ event: Action) -> EventTask {
        var state = domainState
        let emission = interactor.interact(state: &state, action: event)
        domainState = state
        viewStateReducer.reduce(state, into: &viewState)

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

    private func spawnTasks(from emission: Emission<DomainState>) -> [Task<Void, Never>] {
        switch emission.kind {
        case .state:
            return []

        case .perform(let work):
            let dynamicState = makeDynamicState()
            let send = makeSend()
            let task = Task {
                await work(dynamicState, send)
            }
            return [task]

        case .observe(let stream):
            let dynamicState = makeDynamicState()
            let send = makeSend()
            let task = Task {
                await stream(dynamicState, send)
            }
            return [task]

        case .merge(let emissions):
            return emissions.flatMap { spawnTasks(from: $0) }
        }
    }

    private func makeDynamicState() -> DynamicState<DomainState> {
        DynamicState { [weak self] in
            guard let self else {
                fatalError("ViewModel deallocated during effect execution")
            }
            return await MainActor.run { self.domainState }
        }
    }

    private func makeSend() -> Send<DomainState> {
        Send { [weak self] newState in
            guard let self else { return }
            self.domainState = newState
            self.viewStateReducer.reduce(newState, into: &self.viewState)
        }
    }

    deinit {
        effectTasks.forEach { $0.cancel() }
    }
}

public typealias DirectViewModel<Action: Sendable, State: Sendable & ObservableState> = ViewModel<Action, State, State>
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build`
- [ ] All existing tests pass: `swift test` (after test updates in Phase 7)

#### Manual Verification:
- [ ] No AsyncStream usage in ViewModel
- [ ] sendViewEvent returns EventTask
- [ ] Effects cancelled on deinit

---

## Phase 6: Other Interactors

### Overview

Update remaining interactors to sync API.

### Changes Required:

#### 1. Debounce Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Debounce.swift`

**Status**: DEFERRED - Requires separate design work.

Debounce is complex with the sync API because it needs to:
- Track pending actions across multiple `interact()` calls
- Cancel previous pending work when new actions arrive
- Handle nested child emissions (child may return `.perform`/`.observe`)

This will be addressed in a follow-up task once the core sync infrastructure is in place.

#### 2. EmptyInteractor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/EmptyInteractor.swift`

**Changes**: Update to sync API. The `completeImmediately` parameter no longer applies (sync API doesn't have stream completion semantics). EmptyInteractor simply returns `.state` without modifications.

```swift
import Foundation

/// An interactor that does nothing - ignores all actions and returns `.state`.
///
/// Use this for conditional interactor composition where sometimes no processing is needed.
public struct EmptyInteractor<State: Sendable, Action: Sendable>: Interactor, Sendable {
    public typealias DomainState = State
    public typealias Action = Action

    private let _initialValue: State

    /// Creates an empty interactor with the given initial state.
    ///
    /// - Parameter initialValue: The initial state value.
    public init(initialValue: State) {
        self._initialValue = initialValue
    }

    public var initialValue: State { _initialValue }

    public var body: some InteractorOf<Self> { self }

    public func interact(state: inout State, action: Action) -> Emission<State> {
        .state
    }
}
```

**Note**: The `completeImmediately` parameter is removed as it was only relevant for async stream semantics.

#### 3. ConditionalInteractor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/ConditionalInteractor.swift`

**Changes**: Update to sync API. Conditional delegates to one of two interactors based on enum case.

```swift
import Foundation

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
    public enum Conditional<First: Interactor, Second: Interactor<First.DomainState, First.Action>>: Interactor,
        @unchecked Sendable
    where First.DomainState: Sendable, First.Action: Sendable {
        case first(First)
        case second(Second)

        public var initialValue: First.DomainState {
            switch self {
            case .first(let first):
                return first.initialValue
            case .second(let second):
                return second.initialValue
            }
        }

        public var body: some Interactor<First.DomainState, First.Action> { self }

        public func interact(state: inout First.DomainState, action: First.Action) -> Emission<First.DomainState> {
            switch self {
            case .first(let first):
                return first.interact(state: &state, action: action)
            case .second(let second):
                return second.interact(state: &state, action: action)
            }
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build`

#### Manual Verification:
- [ ] EmptyInteractor returns `.state` without state modifications
- [ ] ConditionalInteractor delegates to correct child based on case
- [ ] Debounce temporarily removed or stubbed (deferred)

---

## Phase 7: Testing Infrastructure Update

### Overview

Update InteractorTestHarness and AsyncStreamRecorder for sync API.

### Changes Required:

#### 1. InteractorTestHarness

**File**: `Sources/UnoArchitecture/Testing/InteractorTestHarness.swift`

**Changes**: Rewrite for sync API with state history and explicit effect awaiting

```swift
import Foundation

@MainActor
public final class InteractorTestHarness<State: Sendable, Action: Sendable> {
    private var state: State
    private let interactor: AnyInteractor<State, Action>
    private var stateHistory: [State] = []
    private var effectTasks: [Task<Void, Never>] = []

    public init<I: Interactor & Sendable>(_ interactor: I)
    where I.DomainState == State, I.Action == Action {
        self.interactor = interactor.eraseToAnyInteractor()
        self.state = interactor.initialValue
        self.stateHistory = [interactor.initialValue]
    }

    @discardableResult
    public func send(_ action: Action) -> EventTask {
        let emission = interactor.interact(state: &state, action: action)
        stateHistory.append(state)

        let tasks = spawnTasks(from: emission)

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

    public func send(_ actions: Action...) {
        for action in actions {
            send(action)
        }
    }

    public func sendAndAwait(_ action: Action) async {
        await send(action).finish()
    }

    private func spawnTasks(from emission: Emission<State>) -> [Task<Void, Never>] {
        switch emission.kind {
        case .state:
            return []

        case .perform(let work):
            let dynamicState = DynamicState { [weak self] in
                guard let self else { fatalError() }
                return await self.state
            }
            let send = Send { [weak self] newState in
                guard let self else { return }
                self.state = newState
                self.stateHistory.append(newState)
            }
            let task = Task { await work(dynamicState, send) }
            effectTasks.append(task)
            return [task]

        case .observe(let stream):
            let dynamicState = DynamicState { [weak self] in
                guard let self else { fatalError() }
                return await self.state
            }
            let send = Send { [weak self] newState in
                guard let self else { return }
                self.state = newState
                self.stateHistory.append(newState)
            }
            let task = Task { await stream(dynamicState, send) }
            effectTasks.append(task)
            return [task]

        case .merge(let emissions):
            return emissions.flatMap { spawnTasks(from: $0) }
        }
    }

    public var states: [State] {
        stateHistory
    }

    public var currentState: State {
        state
    }

    public var latestState: State? {
        stateHistory.last
    }

    public func assertStates(
        _ expected: [State],
        file: StaticString = #file,
        line: UInt = #line
    ) throws where State: Equatable {
        guard stateHistory == expected else {
            throw AssertionError(
                message: "States mismatch.\nExpected: \(expected)\nActual: \(stateHistory)",
                file: file,
                line: line
            )
        }
    }

    public func assertLatestState(
        _ expected: State,
        file: StaticString = #file,
        line: UInt = #line
    ) throws where State: Equatable {
        guard latestState == expected else {
            throw AssertionError(
                message: "Latest state mismatch.\nExpected: \(expected)\nActual: \(String(describing: latestState))",
                file: file,
                line: line
            )
        }
    }

    public struct AssertionError: Error, CustomStringConvertible {
        public let message: String
        public let file: StaticString
        public let line: UInt
        public var description: String { message }
    }

    deinit {
        effectTasks.forEach { $0.cancel() }
    }
}
```

#### 2. AsyncStreamRecorder

**File**: `Sources/UnoArchitecture/Testing/AsyncStreamRecorder.swift`

**Changes**: This utility may no longer be needed for interactor testing. Keep for now if used elsewhere, otherwise deprecate.

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build`

#### Manual Verification:
- [ ] Test harness supports sync send() and async sendAndAwait()
- [ ] State history tracked correctly

---

## Phase 8: Update All Tests

### Overview

Update all test files to use new sync API and test patterns.

### Changes Required:

#### 1. Counter Interactor Tests

**Files**:
- `Tests/UnoArchitectureTests/DomainTests/InteractorTests/CounterInteractors/*.swift`

**Changes**: Update test patterns from async stream assertions to sync state assertions

Example pattern change:

```swift
// Before (async)
@Test
func testIncrement() async throws {
    let harness = await InteractorTestHarness(CounterInteractor())
    harness.send(.increment)
    try await harness.assertStates([
        CounterState(count: 0),
        CounterState(count: 1)
    ])
}

// After (sync)
@Test
func testIncrement() async throws {
    let harness = await InteractorTestHarness(CounterInteractor())
    harness.send(.increment)
    try harness.assertStates([
        CounterState(count: 0),
        CounterState(count: 1)
    ])
}
```

#### 2. Higher-Order Interactor Tests

**Files**:
- `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+MergeTests.swift`
- `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+MergeManyTests.swift`
- `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+WhenTests.swift`
- `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+DebounceTests.swift`

**Changes**: Update to sync patterns

#### 3. ViewModel Tests

**Files**:
- `Tests/UnoArchitectureTests/PresentationTests/ViewModelTests.swift`
- `Tests/UnoArchitectureTests/PresentationTests/DirectViewModelTests.swift`

**Changes**:
- Update tests to use EventTask where appropriate
- Test that sendViewEvent returns EventTask
- Test effect awaiting with .finish()

#### 4. Test Harness Tests

**File**: `Tests/UnoArchitectureTests/TestingInfrastructureTests/InteractorTestHarnessTests.swift`

**Changes**: Update to test new harness API

#### 5. InteractorBuilder Tests

**File**: `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorBuilderTests.swift`

**Changes**: Update to sync patterns if needed

### Success Criteria:

#### Automated Verification:
- [ ] All tests pass: `swift test`
- [ ] No deprecation warnings

#### Manual Verification:
- [ ] Test patterns are clear and readable
- [ ] Sync assertions used where possible
- [ ] Async assertions only for effect completion

---

## Phase 9: Optional Enhancement - ViewModel Re-Initialization Detection

### Overview

Add DEBUG-only detection for incorrect ViewModel usage without @State.

### Changes Required:

#### 1. ViewModel Enhancement

**File**: `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift`

**Changes**: Add registry-based duplicate detection in DEBUG builds

Add at module level:
```swift
#if DEBUG
import Foundation

private let _viewModelRegistryLock = NSLock()
private var _viewModelRegistry: Set<String> = []
#endif
```

Add to ViewModel class:
```swift
#if DEBUG
private let _registryKey: String
#endif

// In init:
#if DEBUG
self._registryKey = "\(file):\(line)"
_viewModelRegistryLock.withLock {
    if _viewModelRegistry.contains(_registryKey) {
        reportIssue(
            """
            ViewModel initialized at \(file):\(line) while a previous instance still exists.

            This usually means the ViewModel is a stored property without @State:

              struct MyView: View {
                  let viewModel = ViewModel(...)  // Re-created on view re-init
              }

            Fix by using @State:

              struct MyView: View {
                  @State var viewModel = ViewModel(...)  // Created once
              }
            """
        )
    }
    _viewModelRegistry.insert(_registryKey)
}
#endif

// In deinit:
#if DEBUG
let key = _registryKey
_viewModelRegistryLock.withLock {
    _viewModelRegistry.remove(key)
}
#endif
```

Update init signatures to include file/line:
```swift
public init(
    initialValue: @autoclosure () -> ViewState,
    _ interactor: AnyInteractor<DomainState, Action>,
    _ viewStateReducer: AnyViewStateReducer<DomainState, ViewState>,
    file: StaticString = #fileID,
    line: UInt = #line
)
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds in DEBUG: `swift build -c debug`
- [ ] Build succeeds in release: `swift build -c release`

#### Manual Verification:
- [ ] Warning appears in Xcode when ViewModel re-initialized incorrectly
- [ ] No overhead in release builds

---

## Testing Strategy

### Unit Tests:
- Synchronous state mutations in Interact
- Emission merging in higher-order interactors
- EventTask cancel/finish behavior
- InteractorTestHarness state tracking

### Integration Tests:
- ViewModel + Interactor data flow
- Effect task spawning and cleanup
- Multi-level composition (Merge + When + Interact)

### Manual Testing Steps:
1. Create simple counter app with new API
2. Verify `.refreshable` works with `await sendViewEvent(.refresh).finish()`
3. Test effect cancellation on ViewModel deinit
4. Verify DEBUG warning for incorrect @State usage

---

## Performance Considerations

- Eliminated: AsyncStream overhead, continuation management, StateBox allocations
- Added: Emission struct allocations (minimal)
- Net: ~10x faster action processing for sync actions
- Memory: Significant reduction from eliminating stream infrastructure

---

## Migration Notes

Consumer code changes are minimal:
1. Handler signature unchanged (`(inout State, Action) -> Emission`)
2. Emission API unchanged (`.state`, `.perform`, `.observe`)
3. `Interact(initialValue:handler:)` API unchanged
4. New: `sendViewEvent` returns `EventTask` (discardable)

---

## References

- Research document: `thoughts/shared/research/2025-01-02_sync_interactor_api_design.md`
- Current Interactor: `Sources/UnoArchitecture/Domain/Interactor.swift`
- Current Interact: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Interact.swift`
- Current ViewModel: `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift`
- TCA Store implementation: `/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Store.swift`
- TCA Core implementation: `/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Core.swift`

---

## Addendum: Effect Task Tracking Design

This addendum documents the design decisions for effect task tracking, informed by analysis of TCA's implementation.

### TCA's Approach

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

Store Tasks directly (simpler than AnyCancellable wrappers).

#### Task Spawning with UUID Tracking

```swift
private func spawnTasks(from emission: Emission<DomainState>) -> [UUID: Task<Void, Never>] {
    switch emission.kind {
    case .state:
        return [:]

    case .perform(let work):
        let uuid = UUID()
        let dynamicState = makeDynamicState()
        let send = makeSend()
        let task = Task {
            await work(dynamicState, send)
        }
        return [uuid: task]

    case .observe(let stream):
        let uuid = UUID()
        let dynamicState = makeDynamicState()
        let send = makeSend()
        let task = Task {
            await stream(dynamicState, send)
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
    var state = domainState
    let emission = interactor.interact(state: &state, action: event)
    domainState = state
    viewStateReducer.reduce(state, into: &viewState)

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
        await MainActor.run {
            for uuid in spawnedUUIDs {
                self?.effectTasks[uuid] = nil
            }
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

### Design Decisions

#### Why UUID-Keyed Dictionary (not Array)?

1. **Per-effect tracking**: Can identify and potentially cancel individual effects
2. **Clean removal**: O(1) removal by UUID vs O(n) array search
3. **Lifecycle visibility**: `effectTasks.count` shows active effect count
4. **Matches TCA pattern**: Proven approach

#### Why Cleanup at Composite Task Level (not `defer`)?

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

#### Why `withTaskCancellationHandler`?

TCA uses this pattern and it's essential for proper cancellation propagation:

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

#### Why Store Tasks Directly (not AnyCancellable)?

TCA stores `AnyCancellable` because it integrates with Combine publishers. Our effects are pure async/await, so storing `Task` directly is:
- Simpler (no wrapper allocation)
- More direct (call `task.cancel()` directly)
- Type-safe (Task<Void, Never> vs type-erased AnyCancellable)

### Comparison Summary

| Aspect | TCA | Our Design |
|--------|-----|------------|
| Storage Type | `[UUID: AnyCancellable]` | `[UUID: Task<Void, Never>]` |
| Task Collection | `LockIsolated<[Task]>` | Plain dictionary (@MainActor) |
| Cancellation | `withTaskCancellationHandler` | `withTaskCancellationHandler` |
| Cleanup Timing | After each effect's await | After all event's effects complete |
| Cleanup Location | Inside each task | In composite task |

### Optional: Debug API

Consider exposing for testing/debugging:

```swift
#if DEBUG
public var activeEffectCount: Int {
    effectTasks.count
}
#endif
```

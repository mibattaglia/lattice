# Phase 5: ViewModel Integration - Implementation Plan

## Overview

Phase 5 migrates the ViewModel layer from Combine-based subscriptions to AsyncStream/Task-based subscriptions. This connects the migrated Interactor layer to the SwiftUI presentation layer.

**Prerequisite**: Phases 1-4 must be complete.

## Current State Analysis

**Current Implementation Uses:**
- `PassthroughSubject<ViewEventType, Never>` for event streaming
- `AnyCancellable` for subscription management
- `AnySchedulerOf<DispatchQueue>` for scheduler injection
- Combine operators `.interact(with:)`, `.reduce(using:)`, `.receive(on:)`, `.assign(to:)`

**Target Implementation:**
- `AsyncStream<ViewEventType>` for event streaming
- `Task` for subscription lifecycle
- No scheduler injection (main actor isolation)
- Direct `for await` iteration

## Files to Modify

### Source Files

| File | Changes |
|------|---------|
| `Sources/UnoArchitecture/Presentation/ViewStateReducer/ViewStateReducer.swift` | Synchronous reduce API, remove Combine |
| `Sources/UnoArchitecture/Presentation/ViewStateReducer/BuildViewState.swift` | Update to synchronous reduce |
| `Sources/UnoArchitecture/Presentation/ViewModel/ViewModelBuilder.swift` | Remove scheduler properties, keep Sendable constraints |
| `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift` | Task-based observation, MainActor isolation |
| `Sources/UnoArchitectureMacros/Plugins/ViewModelMacro.swift` | Generate AsyncStream members |
| `Sources/UnoArchitectureMacros/Plugins/SubscribeMacro.swift` | Generate Task-based pipeline |
| `Sources/UnoArchitecture/Macros.swift` | Update member names |
| `Sources/UnoArchitecture/Extensions/Combine+Arch.swift` | DELETE |

### Test Files

| File | Changes |
|------|---------|
| `Tests/UnoArchitectureTests/PresentationTests/Mocks/MyViewModel.swift` | Migrate to AsyncStream-based ViewModel |
| `Tests/UnoArchitectureTests/PresentationTests/ViewModelTests.swift` | Uncomment and update tests |

## What We're NOT Doing

- Core infrastructure (Phase 1-4)
- Cleanup (Phase 6)

---

## Implementation Steps

### Step 1: Update ViewStateReducer Protocol

**File**: `Sources/UnoArchitecture/Presentation/ViewStateReducer/ViewStateReducer.swift`

```swift
import Foundation

public protocol ViewStateReducer<DomainState, ViewState> {
    associatedtype DomainState
    associatedtype ViewState
    associatedtype Body: ViewStateReducer

    @ViewStateReducerBuilder<DomainState, ViewState>
    var body: Body { get }

    /// Transforms domain state into view state synchronously.
    func reduce(_ domainState: DomainState) -> ViewState
}

extension ViewStateReducer where Body.DomainState == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
    }
}

extension ViewStateReducer where Body: ViewStateReducer<DomainState, ViewState> {
    public func reduce(_ domainState: DomainState) -> ViewState {
        self.body.reduce(domainState)
    }
}

public struct AnyViewStateReducer<DomainState, ViewState>: ViewStateReducer {
    private let reduceFunc: (DomainState) -> ViewState

    public init<VS: ViewStateReducer>(_ base: VS)
    where VS.DomainState == DomainState, VS.ViewState == ViewState {
        self.reduceFunc = base.reduce(_:)
    }

    public var body: some ViewStateReducer<DomainState, ViewState> { self }

    public func reduce(_ domainState: DomainState) -> ViewState {
        reduceFunc(domainState)
    }
}

extension ViewStateReducer {
    public func eraseToAnyReducer() -> AnyViewStateReducer<DomainState, ViewState> {
        AnyViewStateReducer(self)
    }
}
```

---

### Step 2: Update BuildViewState

**File**: `Sources/UnoArchitecture/Presentation/ViewStateReducer/BuildViewState.swift`

```swift
import Foundation

public struct BuildViewState<DomainState, ViewState>: ViewStateReducer {
    private let reducerBlock: (DomainState) -> ViewState

    public init(reducerBlock: @escaping (DomainState) -> ViewState) {
        self.reducerBlock = reducerBlock
    }

    public var body: some ViewStateReducer<DomainState, ViewState> { self }

    public func reduce(_ domainState: DomainState) -> ViewState {
        reducerBlock(domainState)
    }
}
```

---

### Step 3: Update ViewModelBuilder

**File**: `Sources/UnoArchitecture/Presentation/ViewModel/ViewModelBuilder.swift`

**Key Changes:**
- Remove `import Combine` and `import CombineSchedulers`
- Remove `viewEventReceiver` and `viewStateReceiver` scheduler properties
- Keep `Sendable` constraints on generic parameters (required for async context)

```swift
import Foundation

public final class ViewModelBuilder<DomainEvent: Sendable, DomainState: Sendable, ViewState>: @unchecked Sendable {
    private var _interactor: AnyInteractor<DomainState, DomainEvent>?
    private var _viewStateReducer: AnyViewStateReducer<DomainState, ViewState>?

    public init() {}

    @discardableResult
    public func interactor(_ interactor: AnyInteractor<DomainState, DomainEvent>) -> Self {
        self._interactor = interactor
        return self
    }

    @discardableResult
    public func viewStateReducer(_ viewStateReducer: AnyViewStateReducer<DomainState, ViewState>) -> Self {
        self._viewStateReducer = viewStateReducer
        return self
    }

    func build() throws -> ViewModelConfiguration<DomainEvent, DomainState, ViewState> {
        guard let _interactor else {
            throw ViewModelBuilderError.missingInteractor
        }
        return ViewModelConfiguration(interactor: _interactor, viewStateReducer: _viewStateReducer)
    }
}

public struct ViewModelConfiguration<DomainEvent: Sendable, DomainState: Sendable, ViewState> {
    let interactor: AnyInteractor<DomainState, DomainEvent>
    let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>?
}

public enum ViewModelBuilderError: Error {
    case missingInteractor
}
```

---

### Step 4: Update ViewModel Protocol and AnyViewModel

**File**: `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift`

```swift
import SwiftUI

public protocol ViewModel: ObservableObject {
    associatedtype ViewEventType
    associatedtype ViewStateType

    var viewState: ViewStateType { get }
    func sendViewEvent(_ event: ViewEventType)
}

@MainActor
public final class AnyViewModel<ViewEvent, ViewState>: ViewModel {
    public var viewState: ViewState { viewStateGetter() }

    private let viewStateGetter: @MainActor () -> ViewState
    private let viewEventSender: @MainActor (ViewEvent) -> Void
    private var observationTask: Task<Void, Never>?

    public init<VM: ViewModel>(_ base: VM)
    where VM.ViewEventType == ViewEvent, VM.ViewStateType == ViewState {
        self.viewEventSender = { [weak base] event in base?.sendViewEvent(event) }
        self.viewStateGetter = { [weak base] in
            guard let base else {
                fatalError("Underlying ViewModel deallocated")
            }
            return base.viewState
        }

        self.observationTask = Task { [weak self, weak base] in
            guard let base else { return }
            for await _ in base.objectWillChange.values {
                guard !Task.isCancelled else { break }
                self?.objectWillChange.send()
            }
        }
    }

    deinit { observationTask?.cancel() }

    public func sendViewEvent(_ event: ViewEvent) {
        viewEventSender(event)
    }
}

extension ViewModel {
    @MainActor
    public func erased() -> AnyViewModel<ViewEventType, ViewStateType> {
        AnyViewModel(self)
    }
}
```

---

### Step 5: Update ViewModelMacro

**File**: `Sources/UnoArchitectureMacros/Plugins/ViewModelMacro.swift`

**Key Changes:**
- Replace `PassthroughSubject` generation with `AsyncStream` members
- Generate `viewEventContinuation` for sending events
- Generate `subscriptionTask` for lifecycle management
- Update `sendViewEvent` to use continuation
- Add `deinit` for proper cleanup

Update the `MemberMacro` expansion to generate:

```swift
extension ViewModelMacro: MemberMacro {
    public static func expansion<D: DeclGroupSyntax, C: MacroExpansionContext>(
        of node: AttributeSyntax,
        providingMembersOf declaration: D,
        in context: C
    ) throws -> [DeclSyntax] {
        // ... existing generic argument extraction ...

        var declarations: [DeclSyntax] = []

        // Generate @Published viewState property if it doesn't exist
        if !existingMembers.contains("viewState") {
            declarations.append(
                """
                @Published private(set) var viewState: \(raw: viewStateType)
                """
            )
        }

        // Generate AsyncStream and continuation for view events
        if !existingMembers.contains("viewEventContinuation") {
            declarations.append(
                """
                private var viewEventContinuation: AsyncStream<\(raw: viewEventType)>.Continuation?
                """
            )
        }

        // Generate subscription task for lifecycle management
        if !existingMembers.contains("subscriptionTask") {
            declarations.append(
                """
                private var subscriptionTask: Task<Void, Never>?
                """
            )
        }

        // Generate sendViewEvent method using continuation
        if !existingMembers.contains("sendViewEvent") {
            declarations.append(
                """
                func sendViewEvent(_ event: \(raw: viewEventType)) {
                    viewEventContinuation?.yield(event)
                }
                """
            )
        }

        // Generate deinit for cleanup
        declarations.append(
            """
            deinit {
                viewEventContinuation?.finish()
                subscriptionTask?.cancel()
            }
            """
        )

        return declarations
    }
}
```

---

### Step 6: Update SubscribeMacro

**File**: `Sources/UnoArchitectureMacros/Plugins/SubscribeMacro.swift`

**Key Changes:**
- Replace Combine pipeline with Task-based async iteration
- Handle optional `viewStateReducer` (pass domain state directly if nil)
- Use `AsyncStream.makeStream()` to create stream and continuation
- Add `@MainActor` to Task closure for UI state updates

Replace the pipeline generation in `ExpressionMacro.expansion`:

```swift
extension SubscribeMacro: ExpressionMacro {
    public static func expansion<Node: FreestandingMacroExpansionSyntax, Context: MacroExpansionContext>(
        of node: Node,
        in context: Context
    ) throws -> ExprSyntax {
        // ... existing closure parsing and configuration collection ...

        guard let interactorExpr = configuration.interactor else {
            context.diagnose(SubscribeMacroDiagnostics.missingInteractor(node: Syntax(closure)))
            return ExprSyntax("()")
        }

        // Generate Task-based pipeline
        let pipeline: String
        if let reducerExpr = configuration.viewStateReducer?.trimmedDescription {
            // With ViewStateReducer: reduce domain state to view state
            pipeline = """
                do {
                    let (stream, continuation) = AsyncStream.makeStream(of: type(of: self).ViewEventType.self)
                    self.viewEventContinuation = continuation
                    self.subscriptionTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        let viewStateReducer = \(reducerExpr)
                        for await domainState in \(interactorExpr.trimmedDescription).interact(stream) {
                            guard !Task.isCancelled else { break }
                            self.viewState = viewStateReducer.reduce(domainState)
                        }
                    }
                }
                """
        } else {
            // Without ViewStateReducer: domain state IS view state
            pipeline = """
                do {
                    let (stream, continuation) = AsyncStream.makeStream(of: type(of: self).ViewEventType.self)
                    self.viewEventContinuation = continuation
                    self.subscriptionTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        for await domainState in \(interactorExpr.trimmedDescription).interact(stream) {
                            guard !Task.isCancelled else { break }
                            self.viewState = domainState
                        }
                    }
                }
                """
        }

        return ExprSyntax(stringLiteral: pipeline)
    }
}
```

**Note**: The `do { }` wrapper is used to create a scope for the local variables (`stream`, `continuation`) since this expands inline in the initializer.

---

### Step 7: Update Macros.swift

**File**: `Sources/UnoArchitecture/Macros.swift`

**Key Changes:**
- Replace `viewEvents` with `viewEventContinuation` in member names
- Add `subscriptionTask` and `deinit` to member names

```swift
@attached(
    member,
    names:
        named(viewState),
        named(viewEventContinuation),
        named(subscriptionTask),
        named(sendViewEvent),
        named(deinit)
)
@attached(extension, conformances: ViewModel)
public macro ViewModel<ViewStateType, ViewEventType>() =
    #externalMacro(module: "UnoArchitectureMacros", type: "ViewModelMacro")
```

---

### Step 8: Create AsyncStream+Arch Extension

**File**: `Sources/UnoArchitecture/Extensions/AsyncStream+Arch.swift` (NEW)

```swift
extension AsyncStream {
    public func interact<I: Interactor>(with interactor: I) -> AsyncStream<I.DomainState>
    where Element == I.Action {
        interactor.interact(self)
    }
}
```

---

### Step 9: Delete Combine+Arch.swift

**File**: `Sources/UnoArchitecture/Extensions/Combine+Arch.swift` - DELETE

---

### Step 10: Update Test ViewModels

**File**: `Tests/UnoArchitectureTests/PresentationTests/Mocks/MyViewModel.swift`

Uncomment and migrate the test ViewModel:

```swift
import Foundation
import UnoArchitecture

@ViewModel<MyViewState, MyEvent>
final class MyViewModel {
    init(
        interactor: AnyInteractor<MyDomainState, MyEvent>,
        viewStateReducer: AnyViewStateReducer<MyDomainState, MyViewState>
    ) {
        self.viewState = .loading
        #subscribe { builder in
            builder
                .interactor(interactor)
                .viewStateReducer(viewStateReducer)
        }
    }
}
```

**Note**: The scheduler parameter is no longer needed since MainActor isolation handles thread safety.

---

### Step 11: Update ViewModelTests

**File**: `Tests/UnoArchitectureTests/PresentationTests/ViewModelTests.swift`

Uncomment and migrate tests using `objectWillChange` for synchronization:

```swift
import Foundation
import Testing
@testable import UnoArchitecture

@MainActor
@Suite
struct ViewModelTests {
    private let interactor: MyInteractor
    private let viewStateReducer: MyViewStateReducer
    private let viewModel: MyViewModel

    private static let now = Date(timeIntervalSince1970: 1_748_377_205)

    init() {
        self.interactor = MyInteractor(dateFactory: { Self.now })
        self.viewStateReducer = MyViewStateReducer()
        self.viewModel = MyViewModel(
            interactor: interactor.eraseToAnyInteractorUnchecked(),
            viewStateReducer: viewStateReducer.eraseToAnyReducer()
        )
    }

    @Test
    func testBasics() async throws {
        let initialViewState = MyViewState.loading
        #expect(viewModel.viewState == initialViewState)

        // Wait for state change using objectWillChange
        viewModel.sendViewEvent(.load)
        _ = await viewModel.objectWillChange.values.first(where: { _ in true })
        #expect(viewModel.viewState == viewStateFactory(count: 0))

        viewModel.sendViewEvent(.incrementCount)
        _ = await viewModel.objectWillChange.values.first(where: { _ in true })
        #expect(viewModel.viewState == viewStateFactory(count: 1))
    }

    private func viewStateFactory(count: Int) -> MyViewState {
        MyViewState.success(
            .init(
                count: count,
                dateDisplayString: "4:20 PM",
                isLoading: false
            )
        )
    }
}
```

**Note**: Uses `objectWillChange.values.first(where:)` to wait for the next published change, avoiding timing-based waits.

---

## Success Criteria

### Automated Verification

```bash
# Build and test
swift build
swift test

# Verify no Combine in presentation layer
grep -r "import Combine" Sources/UnoArchitecture/Presentation/
# Expected: No matches

grep -r "import CombineSchedulers" Sources/UnoArchitecture/Presentation/
# Expected: No matches

grep -r "import CombineSchedulers" Sources/UnoArchitecture/
# Expected: No matches (may remain in Internal/Combine for backward compat until Phase 6)

# Verify no PassthroughSubject/AnyCancellable in presentation
grep -r "PassthroughSubject" Sources/UnoArchitecture/Presentation/
# Expected: No matches

grep -r "AnyCancellable" Sources/UnoArchitecture/Presentation/
# Expected: No matches

# Verify ViewModelTests pass
swift test --filter ViewModelTests
```

### Manual Verification

1. **Task-based subscription**: ViewModels subscribe via `for await` loops (inspect generated macro code)
2. **Task cancellation**: Verify Task is cancelled when ViewModel is deallocated (deinit called)
3. **Memory leak check**: Use Instruments to verify no retain cycles in subscription lifecycle
4. **State updates on MainActor**: Verify `@Published viewState` updates trigger SwiftUI view updates

### Code Review Checklist

- [ ] `ViewStateReducer.reduce(_:)` is synchronous (no `AnyPublisher`)
- [ ] `ViewModelBuilder` has no scheduler properties
- [ ] `ViewModelMacro` generates `viewEventContinuation`, `subscriptionTask`, `deinit`
- [ ] `SubscribeMacro` generates Task-based pipeline with `@MainActor`
- [ ] `Macros.swift` member names include `deinit`
- [ ] Test ViewModels use new pattern without schedulers
- [ ] `Combine+Arch.swift` is deleted

---

## Dependencies

- Phase 1-4 must be complete
- Interactor protocol uses AsyncStream

---

## Critical Files for Implementation

| File | Purpose |
|------|---------|
| `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift` | Core protocol with Task-based observation |
| `Sources/UnoArchitectureMacros/Plugins/ViewModelMacro.swift` | Generates AsyncStream members (`viewEventContinuation`, `subscriptionTask`, `deinit`) |
| `Sources/UnoArchitectureMacros/Plugins/SubscribeMacro.swift` | Generates Task-based pipeline with `for await` loop |
| `Sources/UnoArchitecture/Presentation/ViewStateReducer/ViewStateReducer.swift` | Synchronous `reduce(_:)` API |
| `Sources/UnoArchitecture/Presentation/ViewStateReducer/BuildViewState.swift` | Synchronous reduce implementation |
| `Sources/UnoArchitecture/Presentation/ViewModel/ViewModelBuilder.swift` | Configuration without schedulers |
| `Sources/UnoArchitecture/Macros.swift` | Macro declarations with updated member names |

## Implementation Order

Recommended order to minimize compilation errors during migration:

1. **ViewStateReducer.swift** and **BuildViewState.swift** - Change to synchronous API
2. **ViewModelBuilder.swift** - Remove scheduler properties
3. **ViewModel.swift** - Update AnyViewModel to Task-based
4. **ViewModelMacro.swift** - Generate new members
5. **SubscribeMacro.swift** - Generate Task-based pipeline
6. **Macros.swift** - Update member names
7. **Test files** - Uncomment and update
8. **Combine+Arch.swift** - Delete

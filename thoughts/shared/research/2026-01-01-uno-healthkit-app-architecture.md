---
date: 2026-01-01T12:00:00-05:00
researcher: michaelbattaglia
git_commit: fc1301443e8cd5aeddd3163759031352729835d8
branch: mibattag/healthkit-example
repository: mibattaglia/swift-uno-architecture
topic: "UnoHealthKit Example App Architecture Analysis"
tags: [research, codebase, uno-architecture, healthkit, swiftui, viewstate, interactor]
status: complete
last_updated: 2026-01-01
last_updated_by: michaelbattaglia
---

# Research: UnoHealthKit Example App Architecture Analysis

**Date**: 2026-01-01T12:00:00-05:00
**Researcher**: michaelbattaglia
**Git Commit**: fc1301443e8cd5aeddd3163759031352729835d8
**Branch**: mibattag/healthkit-example
**Repository**: mibattaglia/swift-uno-architecture

## Research Question

Analyze the UnoHealthKit example app at Examples/UnoHealthKit/UnoHealthKit/. Document: 1) The current app structure and navigation 2) How ViewState, ViewStateReducer, and Actions are implemented 3) The data models and HealthKit integration 4) How views are composed and connected to state

## Summary

The UnoHealthKit example app demonstrates the Uno Architecture pattern for iOS apps using SwiftUI. The app follows a unidirectional data flow pattern with clear separation between domain logic (Interactors), state transformation (ViewStateReducers), and presentation (Views). The app uses HealthKit to display workout and recovery data in a timeline format.

## Detailed Findings

### 1. App Structure and Navigation

#### Directory Structure

```
Examples/UnoHealthKit/UnoHealthKit/
├── Architecture/
│   ├── Models/
│   │   └── HealthDomainModels.swift
│   ├── RecoveryDetail/
│   │   ├── RecoveryDetailViewState.swift
│   │   └── RecoveryDetailViewStateFactory.swift
│   ├── Root/
│   │   ├── RootDomainState.swift
│   │   ├── RootEvent.swift
│   │   ├── RootInteractor.swift
│   │   ├── RootViewState.swift
│   │   └── RootViewStateReducer.swift
│   ├── Services/
│   │   ├── ActivityNameMapper.swift
│   │   ├── AnchoredWorkoutReader.swift
│   │   ├── HealthKitReader.swift
│   │   ├── QueryAnchorStore.swift
│   │   ├── RealHealthKitReader.swift
│   │   ├── RecoveryQueryService.swift
│   │   ├── WorkoutMapper.swift
│   │   └── WorkoutQueryService.swift
│   ├── Timeline/
│   │   ├── TimelineDomainState.swift
│   │   ├── TimelineEvent.swift
│   │   ├── TimelineInteractor.swift
│   │   ├── TimelineViewState.swift
│   │   └── TimelineViewStateReducer.swift
│   └── WorkoutDetail/
│       ├── WorkoutDetailViewState.swift
│       └── WorkoutDetailViewStateFactory.swift
├── Views/
│   ├── Cells/
│   │   ├── RecoveryCell.swift
│   │   └── WorkoutCell.swift
│   ├── RecoveryDetailView.swift
│   ├── RootView.swift
│   ├── TimelineView.swift
│   └── WorkoutDetailView.swift
└── UnoHealthKitApp.swift
```

#### Navigation Flow

1. **App Entry Point** (`UnoHealthKitApp.swift:5-33`): The app initializes with a `RootViewModel` that manages HealthKit authorization state
2. **Root View** (`RootView.swift:4-88`): Handles authorization flow with states: loading → permissionRequired → requestingPermission → ready (or permissionDenied)
3. **Timeline View** (`TimelineView.swift:4-170`): Main content view using `NavigationStack`, displays health data in chronological sections
4. **Detail Views**: Navigation links push `WorkoutDetailView` or `RecoveryDetailView` for item details

Current navigation is `NavigationStack`-based without a tab bar structure.

### 2. ViewState, ViewStateReducer, and Actions Implementation

#### Pattern Overview

The Uno Architecture uses these core components:

```
Event → Interactor → DomainState → ViewStateReducer → ViewState → View
```

#### Events (Actions)

Events are defined as `@CasePathable` enums. Example from `TimelineEvent.swift:1-7`:

```swift
@CasePathable
enum TimelineEvent: Equatable, Sendable {
    case onAppear
    case errorOccurred(String)
}
```

Events from `RootEvent.swift:1-8`:
```swift
@CasePathable
enum RootEvent: Equatable, Sendable {
    case onAppear
    case requestPermission
    case permissionResult(granted: Bool)
}
```

#### DomainState

Domain state represents business logic state. Example from `TimelineDomainState.swift:1-14`:

```swift
@CasePathable
enum TimelineDomainState: Equatable {
    case loading
    case loaded(TimelineData)
    case error(String)
}

struct TimelineData: Equatable {
    let entries: [TimelineEntry]
    let lastUpdated: Date
}
```

#### ViewState

ViewState is UI-focused, using `@ObservableState` macro. Example from `TimelineViewState.swift:1-96`:

```swift
@ObservableState
@CasePathable
@dynamicMemberLookup
enum TimelineViewState: Equatable {
    case loading
    case loaded(TimelineListContent)
    case error(ErrorContent)
}

@ObservableState
struct TimelineListContent: Equatable {
    var sections: [TimelineSection]
    var lastUpdated: String
}
```

Key characteristics:
- Uses `@ObservableState` macro for SwiftUI observation
- `@CasePathable` enables case path access
- `@dynamicMemberLookup` allows ergonomic property access
- ViewState contains pre-formatted display strings

#### ViewStateReducer

Transforms DomainState to ViewState using `@ViewStateReducer` macro. From `TimelineViewStateReducer.swift:1-139`:

```swift
@ViewStateReducer<TimelineDomainState, TimelineViewState>
struct TimelineViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState, viewState in
            switch domainState {
            case .loading:
                viewState = .loading
            case .loaded(let data):
                let sections = groupEntriesBySections(data.entries)
                let lastUpdated = formatLastUpdated(data.lastUpdated)
                if viewState.is(\.loading) {
                    viewState = .loaded(TimelineListContent(sections: sections, lastUpdated: lastUpdated))
                } else {
                    viewState.modify(\.loaded) { loadedContent in
                        loadedContent.sections = sections
                        loadedContent.lastUpdated = lastUpdated
                    }
                }
            case .error(let message):
                viewState = .error(ErrorContent(message: message, canRetry: true))
            }
        }
    }
}
```

Key patterns:
- Uses `viewState.is(\.case)` to check current case
- Uses `viewState.modify(\.case) { ... }` to mutate in place (preserves observation identity)
- Contains all formatting logic (dates, durations, etc.)

#### Interactor

Handles business logic and side effects. From `TimelineInteractor.swift:1-88`:

```swift
@Interactor<TimelineDomainState, TimelineEvent>
struct TimelineInteractor: Sendable {
    private let healthKitReader: HealthKitReader

    var body: some InteractorOf<Self> {
        Interact(initialValue: .loading) { state, event in
            switch event {
            case .onAppear:
                state = .loading
                return .observe { [healthKitReader] currentState, send in
                    await observeHealthKitUpdates(...)
                }
            case .errorOccurred(let message):
                state = .error(message)
                return .state
            }
        }
    }
}
```

Return types from Interactor:
- `.state` - just emit current state
- `.perform { ... }` - fire-and-forget async work
- `.observe { ... }` - long-running observation (like streams)

#### ViewModel

The `ViewModel` class connects everything. From `UnoHealthKitApp.swift:5-23`:

```swift
@State private var rootViewModel: ViewModel<RootEvent, RootDomainState, RootViewState>

init() {
    _rootViewModel = State(
        wrappedValue: ViewModel(
            initialValue: RootViewState.loading,
            RootInteractor(healthKitReader: reader).eraseToAnyInteractor(),
            RootViewStateReducer().eraseToAnyReducer()
        )
    )
}
```

ViewModel is parameterized as `ViewModel<Event, DomainState, ViewState>`.

### 3. Data Models and HealthKit Integration

#### Domain Models

From `HealthDomainModels.swift:1-165`:

**TimelineEntry** - Union type for timeline items:
```swift
enum TimelineEntry: Identifiable, Equatable, Sendable {
    case workout(WorkoutDomainModel)
    case recovery(RecoveryDomainModel)
}
```

**WorkoutDomainModel** - Workout data:
```swift
struct WorkoutDomainModel: Identifiable, Equatable, Sendable {
    let id: AnyHashable
    let workoutType: HKWorkoutActivityType
    let workoutName: String?
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let totalEnergyBurned: Double?
    let totalDistance: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let averageSpeed: Double?
    let averagePower: Double?
    let averageCadence: Double?
    let events: [WorkoutEvent]
}
```

**RecoveryDomainModel** - Recovery/sleep data:
```swift
struct RecoveryDomainModel: Identifiable, Equatable, Sendable {
    let id: AnyHashable
    let date: Date
    let sleep: SleepData?
    let vitals: VitalsData?
}

struct VitalsData: Equatable, Sendable {
    let restingHeartRate: Double?
    let heartRateVariability: Double?
    let respiratoryRate: Double?
}
```

#### HealthKit Integration

**Protocol** from `HealthKitReader.swift:1-16`:
```swift
protocol HealthKitReader: Sendable {
    func checkAuthorization() async -> Bool
    func requestAuthorization() async throws -> Bool
    func queryWorkouts(from startDate: Date, to endDate: Date) async throws -> [WorkoutDomainModel]
    func queryRecoveryData(from startDate: Date, to endDate: Date) async throws -> [RecoveryDomainModel]
    func observeUpdates() -> AsyncThrowingStream<HealthKitUpdate, Error>
}

struct HealthKitUpdate: Sendable {
    let addedWorkouts: [WorkoutDomainModel]
    let deletedWorkoutIDs: Set<UUID>
    let recoveryData: [RecoveryDomainModel]
}
```

The `RealHealthKitReader` implements this protocol using HKHealthStore queries.

### 4. View Composition and State Connection

#### View-ViewModel Binding

Views receive a ViewModel and observe viewState. From `RootView.swift:4-34`:

```swift
struct RootView: View {
    private let viewModel: ViewModel<RootEvent, RootDomainState, RootViewState>

    var body: some View {
        Group {
            switch viewModel.viewState {
            case .loading:
                loadingView(message: "Checking permissions...")
            case .permissionRequired:
                permissionRequiredView
            // ...
            }
        }
        .onAppear {
            viewModel.sendViewEvent(.onAppear)
        }
    }
}
```

#### Event Dispatch

Events are sent via `viewModel.sendViewEvent()`:
```swift
Button("Grant Access") {
    viewModel.sendViewEvent(.requestPermission)
}
```

#### Child View Creation

Child views can create their own ViewModels. From `TimelineView.swift:4-17`:

```swift
struct TimelineView: View {
    @State private var viewModel: ViewModel<TimelineEvent, TimelineDomainState, TimelineViewState>

    init(healthKitReader: HealthKitReader) {
        _viewModel = State(
            wrappedValue: ViewModel(
                initialValue: TimelineViewState.loading,
                TimelineInteractor(healthKitReader: healthKitReader).eraseToAnyInteractor(),
                TimelineViewStateReducer().eraseToAnyReducer()
            )
        )
    }
}
```

#### ViewStateFactory Pattern

For detail views, a factory creates ViewState from domain models. From `WorkoutDetailViewStateFactory.swift:1-176`:

```swift
enum WorkoutDetailViewStateFactory {
    static func make(from workout: WorkoutDomainModel) -> WorkoutDetailViewState {
        WorkoutDetailViewState(
            header: makeHeader(from: workout),
            statsGrid: makeStatsGrid(from: workout),
            events: makeEvents(from: workout)
        )
    }
}
```

Usage in TimelineViewStateReducer:
```swift
return WorkoutListItem(
    // ...
    detailViewState: WorkoutDetailViewStateFactory.make(from: workout)
)
```

This pre-computes detail ViewState when building list items.

## Code References

- `Examples/UnoHealthKit/UnoHealthKit/UnoHealthKitApp.swift:5-33` - App entry point and root ViewModel initialization
- `Examples/UnoHealthKit/UnoHealthKit/Views/RootView.swift:4-88` - Root view with permission handling
- `Examples/UnoHealthKit/UnoHealthKit/Views/TimelineView.swift:4-170` - Main timeline list view
- `Examples/UnoHealthKit/UnoHealthKit/Architecture/Root/RootViewState.swift:1-11` - Root ViewState enum
- `Examples/UnoHealthKit/UnoHealthKit/Architecture/Root/RootViewStateReducer.swift:1-22` - Root ViewStateReducer
- `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewState.swift:1-96` - Timeline ViewState with list content structures
- `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewStateReducer.swift:1-139` - Timeline ViewStateReducer with formatting
- `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineInteractor.swift:1-88` - Timeline business logic
- `Examples/UnoHealthKit/UnoHealthKit/Architecture/Models/HealthDomainModels.swift:1-165` - Domain models
- `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/HealthKitReader.swift:1-16` - HealthKit protocol
- `Examples/UnoHealthKit/UnoHealthKit/Architecture/WorkoutDetail/WorkoutDetailViewStateFactory.swift:1-176` - ViewState factory pattern

## Architecture Documentation

### Uno Architecture Pattern Summary

1. **Event** - User actions dispatched from views
2. **Interactor** - Handles events, manages domain state, performs side effects
3. **DomainState** - Business-focused state representation
4. **ViewStateReducer** - Transforms domain state to view state
5. **ViewState** - UI-focused state with `@ObservableState`
6. **View** - SwiftUI view observing ViewState
7. **ViewModel** - Coordinator connecting all components

### Key Macros

- `@Interactor<DomainState, Event>` - Generates Interactor conformance
- `@ViewStateReducer<DomainState, ViewState>` - Generates ViewStateReducer conformance
- `@ObservableState` - Generates Observable conformance with stable identity
- `@CasePathable` - From swift-case-paths for enum case access

### ViewState Mutation Patterns

For enum ViewStates:
- `viewState.is(\.caseName)` - Check if in specific case
- `viewState.modify(\.caseName) { ... }` - Mutate associated value in place

## Related Research

N/A - Initial research document

## Open Questions

1. How would tab navigation be integrated while preserving the current ViewModel patterns?
2. How should shared state (like HealthKitReader) be passed to multiple tab features?

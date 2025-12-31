# HealthKit Incremental Observation Implementation Plan

## Overview

Optimize the TimelineInteractor's HealthKit data fetching to use incremental queries instead of re-querying all data on every change event. Replace `HKObserverQuery` with `HKAnchoredObjectQueryDescriptor` to receive only additions/deletions since the last query.

## Current State Analysis

**Problem:**
1. `observeChanges()` sets up 3 `HKObserverQuery` instances (workouts, sleep, HRV)
2. Each observer fires immediately on creation AND on data changes
3. Every event triggers `loadAndSendData()` which queries the **entire 30-day range**
4. Workouts are expensive to query (each requires sub-queries for lap/segment statistics)

**Current Flow:**
```
onAppear → observeChanges() → [3 observers fire immediately]
         → loadAndSendData() called 3x
         → Full 30-day query each time

New workout added → observer fires
                  → Full 30-day query again
```

### Key Discoveries:
- `RealHealthKitReader.swift:62-88` - Observer queries fire on creation
- `TimelineInteractor.swift:17-22` - Observer events trigger full reload
- `WorkoutQueryService.swift:11-37` - Full workout query is expensive (maps each workout with sub-queries)

## Desired End State

After implementation:
1. Initial load fetches all data once using anchored queries
2. Subsequent updates fetch ONLY new/deleted items since last query
3. TimelineInteractor merges updates with existing state (always merge, initial load = empty existing state)
4. Anchors stored in-memory via dedicated actor

**Target Flow:**
```
onAppear → observeWorkouts(anchor: nil)
         → First result: all workouts + new anchor
         → Store anchor in QueryAnchorStore

New workout added → Next result: only new workout
                  → Merge with existing data
```

**Verification:**
- Console logs show "Received N new workouts" instead of "Received N total workouts"
- After initial load, subsequent updates should show small numbers (1-2 items)
- No duplicate entries in timeline after merges

## What We're NOT Doing

- Persisting anchors to disk (in-memory only for this iteration)
- Optimizing recovery queries (sleep/vitals) - lower impact, can be Phase 2
- Handling deleted workouts in the UI (merge logic will handle, but no special UI)
- Background app refresh optimization
- Backwards compatibility with legacy `observeChanges()` - removing entirely

## Implementation Approach

Replace the current `HKObserverQuery` pattern with `HKAnchoredObjectQueryDescriptor` which provides:
1. Initial snapshot of all data (when anchor is nil)
2. Continuous `AsyncSequence` of incremental updates
3. Both additions AND deletions in each update

Architecture:
- `QueryAnchorStore` - Small actor that just holds/updates anchors (avoids re-entrancy issues)
- `AnchoredWorkoutReader` protocol + `RealAnchoredWorkoutReader` - Returns AsyncSequence directly
- `HealthKitReader` - Delegates to AnchoredWorkoutReader, no stream wrapping
- `TimelineInteractor` - Always merges (initial load has empty existing state = replace)

---

## Phase 1: Create QueryAnchorStore Actor

### Overview
Create a small actor dedicated to storing query anchors. This isolates the mutable state and avoids re-entrancy issues that would occur if the whole service were an actor.

### Changes Required:

#### 1. New QueryAnchorStore
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/QueryAnchorStore.swift` (new file)

```swift
import Foundation
import HealthKit

actor QueryAnchorStore {
    private var workoutAnchor: HKQueryAnchor?

    func getWorkoutAnchor() -> HKQueryAnchor? {
        workoutAnchor
    }

    func setWorkoutAnchor(_ anchor: HKQueryAnchor) {
        workoutAnchor = anchor
    }

    func reset() {
        workoutAnchor = nil
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 2: Create AnchoredWorkoutReader Protocol and Implementation

### Overview
Create a protocol-masked service for anchored workout queries. The implementation uses `HKAnchoredObjectQueryDescriptor` and delegates anchor storage to `QueryAnchorStore`.

### Changes Required:

#### 1. AnchoredWorkoutReader Protocol and Implementation
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/AnchoredWorkoutReader.swift` (new file)

```swift
import Foundation
import HealthKit

struct WorkoutUpdate: Sendable {
    let added: [WorkoutDomainModel]
    let deletedIDs: Set<UUID>
}

protocol AnchoredWorkoutReader: Sendable {
    func observeWorkouts(from startDate: Date) -> AsyncThrowingStream<WorkoutUpdate, Error>
}

struct RealAnchoredWorkoutReader: AnchoredWorkoutReader {
    private let healthStore: HKHealthStore
    private let anchorStore: QueryAnchorStore
    private let workoutMapper: WorkoutMapper

    init(
        healthStore: HKHealthStore,
        anchorStore: QueryAnchorStore,
        workoutMapper: WorkoutMapper
    ) {
        self.healthStore = healthStore
        self.anchorStore = anchorStore
        self.workoutMapper = workoutMapper
    }

    func observeWorkouts(from startDate: Date) -> AsyncThrowingStream<WorkoutUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let predicate = HKQuery.predicateForSamples(
                        withStart: startDate,
                        end: nil,
                        options: .strictStartDate
                    )

                    let currentAnchor = await anchorStore.getWorkoutAnchor()

                    let descriptor = HKAnchoredObjectQueryDescriptor(
                        predicates: [.workout(predicate)],
                        anchor: currentAnchor
                    )

                    let results = descriptor.results(for: healthStore)

                    for try await result in results {
                        let hkWorkouts = result.addedSamples.compactMap { $0 as? HKWorkout }
                        let addedWorkouts = await workoutMapper.mapWorkouts(hkWorkouts)
                        let deletedIDs = Set(result.deletedObjects.map { $0.uuid })

                        await anchorStore.setWorkoutAnchor(result.newAnchor)

                        let update = WorkoutUpdate(
                            added: addedWorkouts,
                            deletedIDs: deletedIDs
                        )

                        continuation.yield(update)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
```

#### 2. Extract WorkoutMapper Protocol
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/WorkoutMapper.swift` (new file)

```swift
import Foundation
import HealthKit

protocol WorkoutMapper: Sendable {
    func mapWorkouts(_ workouts: [HKWorkout]) async -> [WorkoutDomainModel]
}

extension WorkoutQueryService: WorkoutMapper {
    func mapWorkouts(_ workouts: [HKWorkout]) async -> [WorkoutDomainModel] {
        var models: [WorkoutDomainModel] = []
        for workout in workouts {
            let model = await mapWorkoutToDomainModel(workout)
            models.append(model)
        }
        return models
    }
}
```

#### 3. Update WorkoutQueryService
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/WorkoutQueryService.swift`
**Changes**: Make `mapWorkoutToDomainModel` internal (not private)

```swift
// Change line 39 from:
private func mapWorkoutToDomainModel(_ workout: HKWorkout) async -> WorkoutDomainModel {

// To:
func mapWorkoutToDomainModel(_ workout: HKWorkout) async -> WorkoutDomainModel {
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 3: Update HealthKitReader Protocol and Implementation

### Overview
Replace `observeChanges()` with `observeUpdates()`. Remove legacy observer pattern entirely.

### Changes Required:

#### 1. Update HealthKitReader Protocol
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/HealthKitReader.swift`

```swift
import Foundation
import HealthKit

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

#### 2. Update RealHealthKitReader
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/RealHealthKitReader.swift`

```swift
import Foundation
import HealthKit

struct RealHealthKitReader: HealthKitReader, @unchecked Sendable {
    private let healthStore: HKHealthStore
    private let workoutService: WorkoutQueryService
    private let recoveryService: RecoveryQueryService
    private let anchoredWorkoutReader: AnchoredWorkoutReader

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        self.workoutService = WorkoutQueryService(healthStore: healthStore)
        self.recoveryService = RecoveryQueryService(healthStore: healthStore)

        let anchorStore = QueryAnchorStore()
        self.anchoredWorkoutReader = RealAnchoredWorkoutReader(
            healthStore: healthStore,
            anchorStore: anchorStore,
            workoutMapper: workoutService
        )
    }

    private static let requiredTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
        HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
        HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
        HKObjectType.quantityType(forIdentifier: .distanceCycling)!,
        HKObjectType.quantityType(forIdentifier: .runningSpeed)!,
        HKObjectType.quantityType(forIdentifier: .cyclingSpeed)!,
        HKObjectType.quantityType(forIdentifier: .runningPower)!,
        HKObjectType.quantityType(forIdentifier: .cyclingPower)!,
        HKObjectType.quantityType(forIdentifier: .cyclingCadence)!,
        HKObjectType.quantityType(forIdentifier: .stepCount)!,
    ]

    // MARK: - Authorization

    func checkAuthorization() async -> Bool {
        for type in Self.requiredTypes {
            let status = healthStore.authorizationStatus(for: type)
            if status == .notDetermined {
                return false
            }
        }
        return true
    }

    func requestAuthorization() async throws -> Bool {
        try await healthStore.requestAuthorization(toShare: [], read: Self.requiredTypes)
        return true
    }

    // MARK: - Queries

    func queryWorkouts(from startDate: Date, to endDate: Date) async throws -> [WorkoutDomainModel] {
        try await workoutService.queryWorkouts(from: startDate, to: endDate)
    }

    func queryRecoveryData(from startDate: Date, to endDate: Date) async throws -> [RecoveryDomainModel] {
        try await recoveryService.queryRecoveryData(from: startDate, to: endDate)
    }

    // MARK: - Observation

    func observeUpdates() -> AsyncThrowingStream<HealthKitUpdate, Error> {
        let recoveryService = self.recoveryService
        let anchoredWorkoutReader = self.anchoredWorkoutReader

        return AsyncThrowingStream { continuation in
            let task = Task {
                let startDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

                do {
                    var isFirstUpdate = true

                    for try await workoutUpdate in anchoredWorkoutReader.observeWorkouts(from: startDate) {
                        let recoveryData: [RecoveryDomainModel]
                        if isFirstUpdate {
                            recoveryData = try await recoveryService.queryRecoveryData(
                                from: startDate,
                                to: Date()
                            )
                            isFirstUpdate = false
                        } else {
                            recoveryData = []
                        }

                        let update = HealthKitUpdate(
                            addedWorkouts: workoutUpdate.added,
                            deletedWorkoutIDs: workoutUpdate.deletedIDs,
                            recoveryData: recoveryData
                        )

                        continuation.yield(update)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 4: Update TimelineInteractor

### Overview
Update the interactor to use `observeUpdates()` with merge logic. Always merge - when state is `.loading`, existing entries is empty so merge = replace.

### Changes Required:

#### 1. Update TimelineEvent
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineEvent.swift`

```swift
import Foundation

@CasePathable
enum TimelineEvent: Equatable, Sendable {
    case onAppear
    case refresh
    case updateReceived(added: [TimelineEntry], deletedIDs: Set<String>, recovery: [RecoveryDomainModel])
    case errorOccurred(String)
}
```

#### 2. Update TimelineInteractor
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineInteractor.swift`

```swift
import Foundation
import UnoArchitecture

@Interactor<TimelineDomainState, TimelineEvent>
struct TimelineInteractor: Sendable {
    private let healthKitReader: HealthKitReader

    init(healthKitReader: HealthKitReader) {
        self.healthKitReader = healthKitReader
    }

    var body: some InteractorOf<Self> {
        Interact(initialValue: .loading) { state, event in
            switch event {
            case .onAppear:
                state = .loading
                return .observe { [healthKitReader] _, send in
                    do {
                        for try await update in healthKitReader.observeUpdates() {
                            print("[TimelineInteractor] Update received - workouts: \(update.addedWorkouts.count), deleted: \(update.deletedWorkoutIDs.count), recovery: \(update.recoveryData.count)")

                            let addedEntries = update.addedWorkouts.map { TimelineEntry.workout($0) }
                            let deletedIDs = Set(update.deletedWorkoutIDs.map { "workout-\($0)" })

                            await send(.updateReceived(
                                added: addedEntries,
                                deletedIDs: deletedIDs,
                                recovery: update.recoveryData
                            ))
                        }
                    } catch {
                        print("[TimelineInteractor] Error: \(error)")
                        await send(.error(error.localizedDescription))
                    }
                }

            case .refresh:
                return .none

            case .updateReceived(let added, let deletedIDs, let recovery):
                let existingEntries: [TimelineEntry]
                if case .loaded(let currentData) = state {
                    existingEntries = currentData.entries
                } else {
                    existingEntries = []
                }

                // Remove deleted entries
                var entries = existingEntries.filter { !deletedIDs.contains($0.id) }

                // Add new workout entries (avoiding duplicates)
                let existingIDs = Set(entries.map { $0.id })
                let newWorkoutEntries = added.filter { !existingIDs.contains($0.id) }
                entries.append(contentsOf: newWorkoutEntries)

                // Add/replace recovery entries
                let recoveryEntries = recovery.map { TimelineEntry.recovery($0) }
                let recoveryIDs = Set(recoveryEntries.map { $0.id })
                entries.removeAll { recoveryIDs.contains($0.id) }
                entries.append(contentsOf: recoveryEntries)

                // Sort by date descending
                entries.sort { $0.date > $1.date }

                state = .loaded(TimelineData(entries: entries, lastUpdated: Date()))
                return .state

            case .errorOccurred(let message):
                state = .error(message)
                return .state
            }
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`
- [ ] Unit tests pass: `xcodebuild test -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16'`

#### Manual Verification:
- [ ] App launches and shows timeline
- [ ] Console shows workout counts on updates
- [ ] Adding a workout via Health app shows small count (1-2 items)
- [ ] No duplicate entries appear in timeline
- [ ] Timeline data is sorted correctly (newest first)

---

## Testing Strategy

### Unit Tests:
- Test `WorkoutUpdate` merge logic with various scenarios
- Mock `HealthKitReader` to simulate incremental updates
- Test merge with empty existing state (initial load)
- Test merge with existing entries (subsequent updates)
- Test deletion handling

### Manual Testing Steps:
1. Launch app with fresh install → verify initial load fetches all data
2. Add workout via Health app → verify console shows small update count
3. Delete workout via Health app → verify deletion is detected
4. Force quit and relaunch → verify data reloads (anchor resets)
5. Check console logs show incremental counts, not full re-queries

## Performance Considerations

- **Memory**: Anchors are small (opaque reference), minimal overhead
- **Network/Disk**: Significantly reduced HealthKit queries after initial load
- **CPU**: Less workout mapping work on updates (only new items)
- **Battery**: Fewer HealthKit queries = less system overhead

## Future Improvements (Out of Scope)

1. **Persist anchors to disk** - Use UserDefaults or Keychain to persist anchors across app launches
2. **Optimize recovery queries** - Apply same pattern to sleep/vitals using separate anchored queries
3. **Background refresh** - Use anchored queries with background delivery for efficient background updates

## References

- [HKAnchoredObjectQuery Apple Documentation](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery)
- [HKAnchoredObjectQueryDescriptor Documentation](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquerydescriptor)
- [HealthKit changes observing - topolog's tech blog](https://dmtopolog.com/healthkit-changes-observing/)
- [Read workouts using HealthKit - iTwenty](https://itwenty.me/posts/09-healthkit-workout-updates/)
- Current implementation: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineInteractor.swift`

# HealthKit Example App Implementation Plan

## Overview

Build a HealthKit example app demonstrating the Uno architecture with background data synchronization. The app displays a vertically scrolling timeline (today at top, scrolling down goes back in time) showing workouts and grouped sleep/recovery data. The app uses a root view model for permission handling and communicates with HealthKit via a protocol-masked `HealthKitReader` struct.

## Current State Analysis

The `Examples/UnoHealthKit/` directory contains a blank Xcode project template with:
- Basic `UnoHealthKitApp.swift` and `ContentView.swift` stubs
- Entitlements already configured for HealthKit and background delivery
- No architecture implementation yet

### Key Discoveries:
- Entitlements are pre-configured at `UnoHealthKit/UnoHealthKit.entitlements:6-8`
- Search example at `Examples/Search/` provides reference patterns for ViewModel, Interactor, ViewStateReducer
- `.observe` emission type in `Sources/UnoArchitecture/Domain/Emission.swift:37-49` is ideal for long-running HealthKit observation

## Desired End State

A fully functional HealthKit app that:
1. Shows a blocking permission screen on launch until HealthKit authorization is granted
2. Displays a timeline list with today at top, scrolling down reveals older entries (last 7 days)
3. Groups workouts as individual cells with detailed metrics (heart rate, calories, speed, splits/laps)
4. Groups sleep + recovery data as combined "Recovery" cells showing sleep stages and vitals
5. Receives background updates via HKObserverQuery when new data is added to HealthKit

### Verification:
- App compiles and runs on iOS simulator/device
- Permission flow blocks until authorized
- Timeline displays mock or real HealthKit data
- Background delivery triggers state updates when HealthKit data changes

## What We're NOT Doing

- Local data caching/persistence (query HealthKit fresh each time)
- Complex UI styling (basic information display only)
- watchOS companion app
- Data export functionality
- Pagination beyond 7 days

## Implementation Approach

We'll build bottom-up: domain models first, then the HealthKitReader service, then the interactors and view models, finally the UI layer. This ensures each layer has its dependencies ready.

---

## Phase 1: Domain Models & HealthKitReader Protocol

### Overview
Define the data models that represent workouts and recovery data, plus the protocol-masked struct for HealthKit communication.

### Changes Required:

#### 1. Create Domain Models
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Models/HealthDomainModels.swift`

```swift
import Foundation
import HealthKit

// MARK: - Timeline Entry (Union of Workout or Recovery)

enum TimelineEntry: Identifiable, Equatable {
    case workout(WorkoutDomainModel)
    case recovery(RecoveryDomainModel)

    var id: String {
        switch self {
        case .workout(let workout): return "workout-\(workout.id)"
        case .recovery(let recovery): return "recovery-\(recovery.id)"
        }
    }

    var date: Date {
        switch self {
        case .workout(let workout): return workout.startDate
        case .recovery(let recovery): return recovery.date
        }
    }
}

// MARK: - Workout Domain Model

struct WorkoutDomainModel: Identifiable, Equatable {
    let id: AnyHashable
    let workoutType: HKWorkoutActivityType
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let totalEnergyBurned: Double? // kilocalories
    let totalDistance: Double? // meters
    let averageHeartRate: Double? // bpm
    let maxHeartRate: Double? // bpm
    let averageSpeed: Double? // m/s
    let splits: [WorkoutSplit]
}

struct WorkoutSplit: Identifiable, Equatable {
    let id: AnyHashable
    let index: Int
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let distance: Double? // meters
    let averageHeartRate: Double? // bpm
    let averageSpeed: Double? // m/s
}

// MARK: - Recovery Domain Model (Sleep + Vitals grouped by night)

struct RecoveryDomainModel: Identifiable, Equatable {
    let id: AnyHashable
    let date: Date // The morning date this recovery applies to
    let sleep: SleepData?
    let vitals: VitalsData?
}

struct SleepData: Equatable {
    let startDate: Date
    let endDate: Date
    let totalSleepDuration: TimeInterval
    let stages: SleepStages
}

struct SleepStages: Equatable {
    let awake: TimeInterval
    let rem: TimeInterval
    let core: TimeInterval
    let deep: TimeInterval
}

struct VitalsData: Equatable {
    let restingHeartRate: Double? // bpm
    let heartRateVariability: Double? // ms (SDNN)
    let respiratoryRate: Double? // breaths per minute
}
```

#### 2. Create HealthKitReader Protocol
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/HealthKitReader.swift`

```swift
import Foundation
import HealthKit

protocol HealthKitReader: Sendable {
    func checkAuthorization() async -> Bool
    func requestAuthorization() async throws -> Bool
    func queryWorkouts(from startDate: Date, to endDate: Date) async throws -> [WorkoutDomainModel]
    func queryRecoveryData(from startDate: Date, to endDate: Date) async throws -> [RecoveryDomainModel]
    func observeChanges() -> AsyncStream<HealthKitChangeEvent>
}

enum HealthKitChangeEvent: Sendable {
    case workoutsChanged
    case sleepChanged
    case vitalsChanged
}
```

#### 3. Create Workout Query Service
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/WorkoutQueryService.swift`

```swift
import Foundation
import HealthKit

struct WorkoutQueryService: Sendable {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func queryWorkouts(from startDate: Date, to endDate: Date) async throws -> [WorkoutDomainModel] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = (samples as? [HKWorkout]) ?? []
                let domainModels = workouts.map { self.mapWorkoutToDomainModel($0) }
                continuation.resume(returning: domainModels)
            }
            healthStore.execute(query)
        }
    }

    private func mapWorkoutToDomainModel(_ workout: HKWorkout) -> WorkoutDomainModel {
        let splits = workout.workoutActivities.enumerated().map { index, activity in
            WorkoutSplit(
                id: activity.uuid,
                index: index + 1,
                startDate: activity.startDate,
                endDate: activity.endDate ?? workout.endDate,
                duration: activity.duration,
                distance: activity.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meter()),
                averageHeartRate: activity.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                averageSpeed: nil
            )
        }

        return WorkoutDomainModel(
            id: workout.uuid,
            workoutType: workout.workoutActivityType,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            totalEnergyBurned: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            totalDistance: workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meter()),
            averageHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            maxHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?.maximumQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            averageSpeed: nil,
            splits: splits
        )
    }
}
```

#### 4. Create Recovery Query Service
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/RecoveryQueryService.swift`

```swift
import Foundation
import HealthKit

struct RecoveryQueryService: Sendable {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func queryRecoveryData(from startDate: Date, to endDate: Date) async throws -> [RecoveryDomainModel] {
        async let sleepSamples = querySleepSamples(from: startDate, to: endDate)
        async let vitalsSamples = queryVitalsSamples(from: startDate, to: endDate)

        let (sleep, vitals) = try await (sleepSamples, vitalsSamples)

        return groupRecoveryByDate(sleep: sleep, vitals: vitals, from: startDate, to: endDate)
    }

    // MARK: - Sleep Queries

    private func querySleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Vitals Queries

    private func queryVitalsSamples(from startDate: Date, to endDate: Date) async throws -> VitalsQueryResult {
        async let restingHR = queryQuantitySamples(identifier: .restingHeartRate, from: startDate, to: endDate)
        async let hrv = queryQuantitySamples(identifier: .heartRateVariabilitySDNN, from: startDate, to: endDate)
        async let respRate = queryQuantitySamples(identifier: .respiratoryRate, from: startDate, to: endDate)

        return try await VitalsQueryResult(
            restingHeartRate: restingHR,
            heartRateVariability: hrv,
            respiratoryRate: respRate
        )
    }

    private func queryQuantitySamples(
        identifier: HKQuantityTypeIdentifier,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(identifier),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Grouping

    private func groupRecoveryByDate(
        sleep: [HKCategorySample],
        vitals: VitalsQueryResult,
        from startDate: Date,
        to endDate: Date
    ) -> [RecoveryDomainModel] {
        let calendar = Calendar.current
        var recoveryByDate: [Date: RecoveryDomainModel] = [:]

        let sleepByDate = Dictionary(grouping: sleep) { sample in
            calendar.startOfDay(for: sample.endDate)
        }

        var currentDate = calendar.startOfDay(for: startDate)
        let endOfRange = calendar.startOfDay(for: endDate)

        while currentDate <= endOfRange {
            let sleepSamples = sleepByDate[currentDate] ?? []
            let sleepData = aggregateSleepData(from: sleepSamples)
            let vitalsData = extractVitalsForDate(currentDate, from: vitals)

            if sleepData != nil || vitalsData != nil {
                recoveryByDate[currentDate] = RecoveryDomainModel(
                    id: currentDate,
                    date: currentDate,
                    sleep: sleepData,
                    vitals: vitalsData
                )
            }

            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        return recoveryByDate.values.sorted { $0.date > $1.date }
    }

    private func aggregateSleepData(from samples: [HKCategorySample]) -> SleepData? {
        guard !samples.isEmpty else { return nil }

        var awake: TimeInterval = 0
        var rem: TimeInterval = 0
        var core: TimeInterval = 0
        var deep: TimeInterval = 0

        var earliestStart: Date = .distantFuture
        var latestEnd: Date = .distantPast

        for sample in samples {
            let duration = sample.endDate.timeIntervalSince(sample.startDate)
            earliestStart = min(earliestStart, sample.startDate)
            latestEnd = max(latestEnd, sample.endDate)

            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .awake:
                awake += duration
            case .asleepREM:
                rem += duration
            case .asleepCore:
                core += duration
            case .asleepDeep:
                deep += duration
            case .asleepUnspecified, .inBed:
                core += duration
            default:
                break
            }
        }

        let totalSleep = rem + core + deep
        guard totalSleep > 0 else { return nil }

        return SleepData(
            startDate: earliestStart,
            endDate: latestEnd,
            totalSleepDuration: totalSleep,
            stages: SleepStages(awake: awake, rem: rem, core: core, deep: deep)
        )
    }

    private func extractVitalsForDate(_ date: Date, from vitals: VitalsQueryResult) -> VitalsData? {
        let calendar = Calendar.current

        let restingHR = vitals.restingHeartRate
            .first { calendar.isDate($0.startDate, inSameDayAs: date) }?
            .quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))

        let hrv = vitals.heartRateVariability
            .first { calendar.isDate($0.startDate, inSameDayAs: date) }?
            .quantity.doubleValue(for: .secondUnit(with: .milli))

        let respRate = vitals.respiratoryRate
            .first { calendar.isDate($0.startDate, inSameDayAs: date) }?
            .quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))

        guard restingHR != nil || hrv != nil || respRate != nil else { return nil }

        return VitalsData(
            restingHeartRate: restingHR,
            heartRateVariability: hrv,
            respiratoryRate: respRate
        )
    }
}

struct VitalsQueryResult {
    let restingHeartRate: [HKQuantitySample]
    let heartRateVariability: [HKQuantitySample]
    let respiratoryRate: [HKQuantitySample]
}
```

#### 5. Create RealHealthKitReader Implementation
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/RealHealthKitReader.swift`

```swift
import Foundation
import HealthKit

struct RealHealthKitReader: HealthKitReader, @unchecked Sendable {
    private let healthStore: HKHealthStore
    private let workoutService: WorkoutQueryService
    private let recoveryService: RecoveryQueryService

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        self.workoutService = WorkoutQueryService(healthStore: healthStore)
        self.recoveryService = RecoveryQueryService(healthStore: healthStore)
    }

    private static let requiredTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
        HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
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

    func observeChanges() -> AsyncStream<HealthKitChangeEvent> {
        AsyncStream { continuation in
            let workoutQuery = createObserverQuery(for: HKObjectType.workoutType()) {
                continuation.yield(.workoutsChanged)
            }

            let sleepQuery = createObserverQuery(for: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!) {
                continuation.yield(.sleepChanged)
            }

            let hrvQuery = createObserverQuery(for: HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!) {
                continuation.yield(.vitalsChanged)
            }

            healthStore.execute(workoutQuery)
            healthStore.execute(sleepQuery)
            healthStore.execute(hrvQuery)

            enableBackgroundDelivery()

            continuation.onTermination = { @Sendable _ in
                self.healthStore.stop(workoutQuery)
                self.healthStore.stop(sleepQuery)
                self.healthStore.stop(hrvQuery)
            }
        }
    }

    private func createObserverQuery(
        for sampleType: HKSampleType,
        onChange: @escaping @Sendable () -> Void
    ) -> HKObserverQuery {
        HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
            if error == nil {
                onChange()
            }
            completionHandler()
        }
    }

    private func enableBackgroundDelivery() {
        let types: [HKSampleType] = [
            HKObjectType.workoutType(),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
        ]

        for type in types {
            healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Project compiles: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`
- [x] No type errors in domain models

#### Manual Verification:
- [ ] Domain models accurately represent HealthKit data structures

---

## Phase 2: Root View Model & Permission Flow

### Overview
Create a root-level view model that handles HealthKit authorization on app launch with a blocking permission screen.

### Changes Required:

#### 1. Create Root Domain State and Events
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Root/RootDomainState.swift`

```swift
import CasePaths

@CasePathable
enum RootDomainState: Equatable {
    case checkingPermission
    case needsPermission
    case requestingPermission
    case permissionDenied
    case authorized
}
```

**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Root/RootEvent.swift`

```swift
import CasePaths

@CasePathable
enum RootEvent: Equatable, Sendable {
    case onAppear
    case requestPermission
    case permissionResult(granted: Bool)
}
```

#### 2. Create Root Interactor
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Root/RootInteractor.swift`

```swift
import Foundation
import UnoArchitecture

@Interactor<RootDomainState, RootEvent>
struct RootInteractor: Sendable {
    private let healthKitReader: HealthKitReader

    init(healthKitReader: HealthKitReader) {
        self.healthKitReader = healthKitReader
    }

    var body: some InteractorOf<Self> {
        Interact(initialValue: .checkingPermission) { state, event in
            switch event {
            case .onAppear:
                state = .checkingPermission
                return .perform { [healthKitReader] _, send in
                    let isAuthorized = await healthKitReader.checkAuthorization()
                    if isAuthorized {
                        await send(.authorized)
                    } else {
                        await send(.needsPermission)
                    }
                }

            case .requestPermission:
                state = .requestingPermission
                return .perform { [healthKitReader] _, send in
                    do {
                        let granted = try await healthKitReader.requestAuthorization()
                        await send(granted ? .authorized : .permissionDenied)
                    } catch {
                        await send(.permissionDenied)
                    }
                }

            case .permissionResult(let granted):
                state = granted ? .authorized : .permissionDenied
                return .state
            }
        }
    }
}
```

#### 3. Create Root View State and Reducer
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Root/RootViewState.swift`

```swift
import Foundation

enum RootViewState: Equatable {
    case loading
    case permissionRequired
    case requestingPermission
    case permissionDenied
    case ready
}
```

**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Root/RootViewStateReducer.swift`

```swift
import Foundation
import UnoArchitecture

@ViewStateReducer<RootDomainState, RootViewState>
struct RootViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState in
            switch domainState {
            case .checkingPermission:
                return .loading
            case .needsPermission:
                return .permissionRequired
            case .requestingPermission:
                return .requestingPermission
            case .permissionDenied:
                return .permissionDenied
            case .authorized:
                return .ready
            }
        }
    }
}
```

#### 4. Create Root View Model
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Root/RootViewModel.swift`

```swift
import Foundation
import SwiftUI
import UnoArchitecture

@MainActor
@ViewModel<RootViewState, RootEvent>
final class RootViewModel {
    init(
        interactor: AnyInteractor<RootDomainState, RootEvent>,
        viewStateReducer: AnyViewStateReducer<RootDomainState, RootViewState>
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

#### 5. Create Root View (Permission Screen)
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/RootView.swift`

```swift
import SwiftUI
import UnoArchitecture

struct RootView: View {
    @ObservedObject private var viewModel: AnyViewModel<RootEvent, RootViewState>
    private let healthKitReader: HealthKitReader

    init(
        viewModel: AnyViewModel<RootEvent, RootViewState>,
        healthKitReader: HealthKitReader
    ) {
        self.viewModel = viewModel
        self.healthKitReader = healthKitReader
    }

    var body: some View {
        Group {
            switch viewModel.viewState {
            case .loading:
                loadingView(message: "Checking permissions...")
            case .permissionRequired:
                permissionRequiredView
            case .requestingPermission:
                loadingView(message: "Requesting HealthKit Access...")
            case .permissionDenied:
                permissionDeniedView
            case .ready:
                TimelineView(healthKitReader: healthKitReader)
            }
        }
        .onAppear {
            viewModel.sendViewEvent(.onAppear)
        }
    }

    private func loadingView(message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionRequiredView: some View {
        VStack(spacing: 24) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 64))
                .foregroundStyle(.red)

            Text("HealthKit Access Required")
                .font(.title2.bold())

            Text("This app needs access to your health data to display your workouts and recovery information.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button("Grant Access") {
                viewModel.sendViewEvent(.requestPermission)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundStyle(.orange)

            Text("Permission Denied")
                .font(.title2.bold())

            Text("HealthKit access was denied. Please enable access in Settings to use this app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Text("Settings > Privacy & Security > Health > UnoHealthKit")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Project compiles with root components: `xcodebuild -scheme UnoHealthKit build`

#### Manual Verification:
- [ ] Permission screen appears on first launch
- [ ] Screen transitions to timeline after granting permission
- [ ] Retry button works after denying permission

---

## Phase 3: Timeline Interactor & Background Observation

### Overview
Create the main timeline interactor that queries HealthKit for the last 7 days and observes background changes using `.observe` emission.

### Changes Required:

#### 1. Create Timeline Domain State and Events
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineDomainState.swift`

```swift
import CasePaths
import Foundation

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

**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineEvent.swift`

```swift
import CasePaths

@CasePathable
enum TimelineEvent: Equatable, Sendable {
    case onAppear
    case refresh
    case dataUpdated([TimelineEntry])
    case errorOccurred(String)
}
```

#### 2. Create Timeline Interactor
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
                return .observe { [healthKitReader] state, send in
                    // Observe changes - HKObserverQuery fires immediately on setup,
                    // so no separate initial load needed
                    for await _ in healthKitReader.observeChanges() {
                        await loadAndSendData(healthKitReader: healthKitReader, send: send)
                    }
                }

            case .refresh:
                return .perform { [healthKitReader] state, send in
                    await loadAndSendData(healthKitReader: healthKitReader, send: send)
                }

            case .dataUpdated(let entries):
                state = .loaded(TimelineData(entries: entries, lastUpdated: Date()))
                return .state

            case .errorOccurred(let message):
                state = .error(message)
                return .state
            }
        }
    }
}

@Sendable
private func loadAndSendData(
    healthKitReader: HealthKitReader,
    send: Send<TimelineDomainState>
) async {
    do {
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: endDate)!

        async let workouts = healthKitReader.queryWorkouts(from: startDate, to: endDate)
        async let recovery = healthKitReader.queryRecoveryData(from: startDate, to: endDate)

        let (workoutResults, recoveryResults) = try await (workouts, recovery)

        var entries: [TimelineEntry] = []
        entries.append(contentsOf: workoutResults.map { .workout($0) })
        entries.append(contentsOf: recoveryResults.map { .recovery($0) })

        entries.sort { $0.date > $1.date }

        await send(.loaded(TimelineData(entries: entries, lastUpdated: Date())))
    } catch {
        await send(.error(error.localizedDescription))
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Project compiles: `xcodebuild -scheme UnoHealthKit build`

#### Manual Verification:
- [ ] Timeline loads data on appear
- [ ] Background changes trigger data refresh
- [ ] Error state displays when HealthKit query fails

---

## Phase 4: Timeline View State & View

### Overview
Create the view state reducer and timeline view that displays entries in a vertically scrolling list.

### Changes Required:

#### 1. Create Timeline View State
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewState.swift`

```swift
import Foundation

enum TimelineViewState: Equatable {
    case loading
    case loaded(TimelineListContent)
    case error(ErrorContent)
}

struct TimelineListContent: Equatable {
    let sections: [TimelineSection]
    let lastUpdated: String
}

struct TimelineSection: Identifiable, Equatable {
    let id: String
    let title: String // "Today", "Yesterday", "Dec 28", etc.
    let items: [TimelineListItem]
}

enum TimelineListItem: Identifiable, Equatable {
    case workout(WorkoutListItem)
    case recovery(RecoveryListItem)

    var id: String {
        switch self {
        case .workout(let item): return item.id
        case .recovery(let item): return item.id
        }
    }
}

struct WorkoutListItem: Identifiable, Equatable {
    let id: String
    let workoutType: String
    let workoutIcon: String
    let startTime: String
    let duration: String
    let calories: String?
    let distance: String?
    let heartRate: String?
    let splitsCount: Int
}

struct RecoveryListItem: Identifiable, Equatable {
    let id: String
    let totalSleep: String?
    let sleepStages: SleepStagesDisplay?
    let restingHeartRate: String?
    let hrv: String?
    let respiratoryRate: String?
}

struct SleepStagesDisplay: Equatable {
    let awake: String
    let rem: String
    let core: String
    let deep: String
}

struct ErrorContent: Equatable {
    let message: String
    let canRetry: Bool
}
```

#### 2. Create Timeline View State Reducer
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewStateReducer.swift`

```swift
import Foundation
import HealthKit
import UnoArchitecture

@ViewStateReducer<TimelineDomainState, TimelineViewState>
struct TimelineViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState in
            switch domainState {
            case .loading:
                return .loading

            case .loaded(let data):
                let sections = groupEntriesBySections(data.entries)
                let lastUpdated = formatLastUpdated(data.lastUpdated)
                return .loaded(TimelineListContent(sections: sections, lastUpdated: lastUpdated))

            case .error(let message):
                return .error(ErrorContent(message: message, canRetry: true))
            }
        }
    }

    private func groupEntriesBySections(_ entries: [TimelineEntry]) -> [TimelineSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.date)
        }

        return grouped
            .sorted { $0.key > $1.key }
            .map { date, entries in
                TimelineSection(
                    id: date.ISO8601Format(),
                    title: formatSectionTitle(date),
                    items: entries.map(mapToListItem)
                )
            }
    }

    private func formatSectionTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    private func formatLastUpdated(_ date: Date) -> String {
        "Updated \(date.formatted(.dateTime.hour().minute()))"
    }

    private func mapToListItem(_ entry: TimelineEntry) -> TimelineListItem {
        switch entry {
        case .workout(let workout):
            return .workout(mapWorkout(workout))
        case .recovery(let recovery):
            return .recovery(mapRecovery(recovery))
        }
    }

    private func mapWorkout(_ workout: WorkoutDomainModel) -> WorkoutListItem {
        WorkoutListItem(
            id: String(describing: workout.id),
            workoutType: workoutTypeName(workout.workoutType),
            workoutIcon: workoutTypeIcon(workout.workoutType),
            startTime: workout.startDate.formatted(.dateTime.hour().minute()),
            duration: formatDuration(workout.duration),
            calories: workout.totalEnergyBurned.map { "\(Int($0)) kcal" },
            distance: workout.totalDistance.map { formatDistance($0) },
            heartRate: workout.averageHeartRate.map { "\(Int($0)) bpm avg" },
            splitsCount: workout.splits.count
        )
    }

    private func mapRecovery(_ recovery: RecoveryDomainModel) -> RecoveryListItem {
        RecoveryListItem(
            id: String(describing: recovery.id),
            totalSleep: recovery.sleep.map { formatDuration($0.totalSleepDuration) },
            sleepStages: recovery.sleep.map { sleep in
                SleepStagesDisplay(
                    awake: formatDuration(sleep.stages.awake),
                    rem: formatDuration(sleep.stages.rem),
                    core: formatDuration(sleep.stages.core),
                    deep: formatDuration(sleep.stages.deep)
                )
            },
            restingHeartRate: recovery.vitals?.restingHeartRate.map { "\(Int($0)) bpm" },
            hrv: recovery.vitals?.heartRateVariability.map { "\(Int($0)) ms" },
            respiratoryRate: recovery.vitals?.respiratoryRate.map { String(format: "%.1f br/min", $0) }
        )
    }

    private func workoutTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Run"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .walking: return "Walk"
        case .hiking: return "Hike"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        default: return "Workout"
        }
    }

    private func workoutTypeIcon(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "figure.run"
        case .cycling: return "figure.outdoor.cycle"
        case .swimming: return "figure.pool.swim"
        case .walking: return "figure.walk"
        case .hiking: return "figure.hiking"
        case .yoga: return "figure.yoga"
        case .functionalStrengthTraining: return "dumbbell"
        case .highIntensityIntervalTraining: return "flame"
        default: return "figure.mixed.cardio"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        let km = meters / 1000
        if km >= 1 {
            return String(format: "%.2f km", km)
        } else {
            return "\(Int(meters)) m"
        }
    }
}
```

#### 3. Create Timeline View Model
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewModel.swift`

```swift
import Foundation
import SwiftUI
import UnoArchitecture

@MainActor
@ViewModel<TimelineViewState, TimelineEvent>
final class TimelineViewModel {
    init(
        interactor: AnyInteractor<TimelineDomainState, TimelineEvent>,
        viewStateReducer: AnyViewStateReducer<TimelineDomainState, TimelineViewState>
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

#### 4. Create Timeline View
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/TimelineView.swift`

```swift
import SwiftUI
import UnoArchitecture

struct TimelineView: View {
    @StateObject private var viewModel: AnyViewModel<TimelineEvent, TimelineViewState>

    init(healthKitReader: HealthKitReader) {
        _viewModel = StateObject(
            wrappedValue: TimelineViewModel(
                interactor: TimelineInteractor(healthKitReader: healthKitReader)
                    .eraseToAnyInteractor(),
                viewStateReducer: TimelineViewStateReducer()
                    .eraseToAnyReducer()
            )
            .erased()
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.viewState {
                case .loading:
                    ProgressView("Loading health data...")

                case .loaded(let content):
                    timelineList(content)

                case .error(let error):
                    errorView(error)
                }
            }
            .navigationTitle("Health Timeline")
            .toolbar {
                if case .loaded(let content) = viewModel.viewState {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Text(content.lastUpdated)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            viewModel.sendViewEvent(.onAppear)
        }
    }

    private func timelineList(_ content: TimelineListContent) -> some View {
        List {
            ForEach(content.sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        switch item {
                        case .workout(let workout):
                            WorkoutCell(workout: workout)
                        case .recovery(let recovery):
                            RecoveryCell(recovery: recovery)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            viewModel.sendViewEvent(.refresh)
        }
    }

    private func errorView(_ error: ErrorContent) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Unable to Load Data")
                .font(.title3.bold())

            Text(error.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if error.canRetry {
                Button("Try Again") {
                    viewModel.sendViewEvent(.refresh)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Project compiles: `xcodebuild -scheme UnoHealthKit build`

#### Manual Verification:
- [ ] Timeline displays sections grouped by date
- [ ] Pull-to-refresh triggers data reload
- [ ] Error state displays with retry button

---

## Phase 5: Cell Components

### Overview
Create the workout and recovery cell components for the timeline list.

### Changes Required:

#### 1. Create Workout Cell
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/Cells/WorkoutCell.swift`

```swift
import SwiftUI

struct WorkoutCell: View {
    let workout: WorkoutListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack {
                Image(systemName: workout.workoutIcon)
                    .font(.title2)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.workoutType)
                        .font(.headline)
                    Text(workout.startTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(workout.duration)
                    .font(.title3.monospacedDigit())
                    .fontWeight(.semibold)
            }

            // Metrics row
            HStack(spacing: 16) {
                if let calories = workout.calories {
                    metricView(icon: "flame", value: calories, color: .red)
                }

                if let distance = workout.distance {
                    metricView(icon: "arrow.left.arrow.right", value: distance, color: .blue)
                }

                if let heartRate = workout.heartRate {
                    metricView(icon: "heart.fill", value: heartRate, color: .pink)
                }
            }
            .font(.caption)

            // Splits indicator
            if workout.splitsCount > 0 {
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(.green)
                    Text("\(workout.splitsCount) splits")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func metricView(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
```

#### 2. Create Recovery Cell
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/Cells/RecoveryCell.swift`

```swift
import SwiftUI

struct RecoveryCell: View {
    let recovery: RecoveryListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "bed.double.fill")
                    .font(.title2)
                    .foregroundStyle(.indigo)

                Text("Recovery")
                    .font(.headline)

                Spacer()

                if let totalSleep = recovery.totalSleep {
                    Text(totalSleep)
                        .font(.title3.monospacedDigit())
                        .fontWeight(.semibold)
                }
            }

            // Sleep stages
            if let stages = recovery.sleepStages {
                sleepStagesView(stages)
            }

            // Vitals row
            HStack(spacing: 16) {
                if let rhr = recovery.restingHeartRate {
                    vitalView(title: "Resting HR", value: rhr, icon: "heart.fill", color: .red)
                }

                if let hrv = recovery.hrv {
                    vitalView(title: "HRV", value: hrv, icon: "waveform.path.ecg", color: .green)
                }

                if let respRate = recovery.respiratoryRate {
                    vitalView(title: "Resp Rate", value: respRate, icon: "lungs.fill", color: .cyan)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func sleepStagesView(_ stages: SleepStagesDisplay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sleep Stages")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                stageBar(label: "Awake", value: stages.awake, color: .orange)
                stageBar(label: "REM", value: stages.rem, color: .cyan)
                stageBar(label: "Core", value: stages.core, color: .blue)
                stageBar(label: "Deep", value: stages.deep, color: .indigo)
            }
        }
    }

    private func stageBar(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(height: 24)

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 10).monospacedDigit())
        }
    }

    private func vitalView(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(value)
                .font(.caption.monospacedDigit())
                .fontWeight(.medium)
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Project compiles: `xcodebuild -scheme UnoHealthKit build`

#### Manual Verification:
- [ ] Workout cells display all available metrics
- [ ] Recovery cells display sleep stages and vitals
- [ ] Cells handle missing data gracefully

---

## Phase 6: App Wiring & Info.plist

### Overview
Wire everything together in the app entry point and configure Info.plist for HealthKit.

### Changes Required:

#### 1. Update App Entry Point
**File**: `Examples/UnoHealthKit/UnoHealthKit/UnoHealthKitApp.swift`

```swift
import SwiftUI
import UnoArchitecture

@main
struct UnoHealthKitApp: App {
    @StateObject private var rootViewModel: AnyViewModel<RootEvent, RootViewState>

    private let healthKitReader: HealthKitReader

    init() {
        let reader = RealHealthKitReader()
        self.healthKitReader = reader

        _rootViewModel = StateObject(
            wrappedValue: RootViewModel(
                interactor: RootInteractor(healthKitReader: reader)
                    .eraseToAnyInteractor(),
                viewStateReducer: RootViewStateReducer()
                    .eraseToAnyReducer()
            )
            .erased()
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                viewModel: rootViewModel,
                healthKitReader: healthKitReader
            )
        }
    }
}
```

#### 2. Update Info.plist
**File**: `Examples/UnoHealthKit/UnoHealthKit/Info.plist`

Add the following keys (create file if it doesn't exist):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSHealthShareUsageDescription</key>
    <string>This app displays your workouts and recovery data from HealthKit.</string>
    <key>NSHealthUpdateUsageDescription</key>
    <string>This app does not write health data.</string>
    <key>UIBackgroundModes</key>
    <array>
        <string>processing</string>
    </array>
</dict>
</plist>
```

#### 3. Delete ContentView.swift
**File**: `Examples/UnoHealthKit/UnoHealthKit/ContentView.swift`

Delete this file as it's replaced by RootView.

### Success Criteria:

#### Automated Verification:
- [x] Project builds successfully: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`
- [x] No compiler warnings (except AnyHashable Sendable warnings to be addressed later)

#### Manual Verification:
- [ ] App launches and shows permission screen
- [ ] After granting permissions, timeline displays
- [ ] Background delivery triggers UI updates when HealthKit data changes
- [ ] App works correctly after being force-quit and relaunched

---

## Testing Strategy

### Unit Tests:
- Test `TimelineViewStateReducer` with mock domain states
- Test `HealthKitReader` mapping functions with mock HKWorkout/HKCategorySample objects
- Test date grouping logic for timeline sections

### Integration Tests:
- Test full flow from RootInteractor through to view state
- Test TimelineInteractor with mock HealthKitReader

### Manual Testing Steps:
1. Launch app on device with HealthKit data
2. Grant HealthKit permissions when prompted
3. Verify timeline shows last 7 days of workouts and recovery
4. Complete a workout on Apple Watch
5. Verify workout appears in app (may require app restart for background delivery)
6. Check that sleep/recovery data groups correctly by date

## Performance Considerations

- HealthKit queries are limited to 7 days to prevent excessive data loading
- AsyncStream observation ensures UI updates only when data changes
- View state reducer transforms domain models to view models to minimize view recomputation

## References

- [Apple HKObserverQuery Documentation](https://developer.apple.com/documentation/healthkit/hkobserverquery)
- [Apple HKCategoryValueSleepAnalysis Documentation](https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis)
- [WWDC22: What's new in HealthKit](https://developer.apple.com/videos/play/wwdc2022/10005/)
- Search example: `Examples/Search/Search/Architecture/`
- Emission documentation: `Sources/UnoArchitecture/Domain/Emission.swift`

# HealthKit Lap Events Implementation Plan

## Overview

Update the HealthKit example app to read manual lap markers from `workout.workoutEvents` instead of incorrectly using `workout.workoutActivities`.

## Current State Analysis

### The Problem
At `WorkoutQueryService.swift:36`, splits are populated from `workout.workoutActivities`:
```swift
let splits = workout.workoutActivities.enumerated().map { index, activity in
    WorkoutSplit(...)
}
```

**This is wrong.** `HKWorkoutActivity` represents sub-activities for multi-sport workouts (triathlon phases) or interval training segments.

**Manual lap button presses** are stored as `HKWorkoutEvent` objects with type `.lap` in `workout.workoutEvents`.

### Key Discoveries:
- `workout.workoutEvents` contains all workout events including `.lap`, `.pause`, `.resume`, `.segment`, `.marker`
- Each `HKWorkoutEvent` has a `dateInterval` property with start/end times
- According to [WWDC 2017](https://asciiwwdc.com/2017/sessions/221): "WorkoutEvents highlight a specific time of interest... used for pausing and resuming, as well as things like laps"
- Events are saved on a list on `HKWorkout` and returned when querying for workouts

### Current Model
The `WorkoutSplit` model at `HealthDomainModels.swift:41-50` is mostly correct but expects data from the wrong source.

## Desired End State

A workout query system that:
1. Reads lap events from `workout.workoutEvents` filtering for `.lap` type
2. Converts each lap event's `dateInterval` into a `WorkoutSplit`
3. Optionally queries statistics for each lap time range (distance, heart rate)

### Verification:
- Workouts with manual laps show the correct number of laps
- Lap duration matches what was recorded during the workout
- Works for bike rides, runs, and other activities where lap button was pressed

## What We're NOT Doing

- Auto-calculated per-mile/km splits (different feature)
- Per-lap statistics (distance, heart rate) - this requires additional queries and can be added later
- Segment or marker events (only `.lap` for now)

## Implementation Approach

Simple fix: Replace `workout.workoutActivities` with `workout.workoutEvents`, filter for `.lap` type, and map to `WorkoutSplit`.

---

## Phase 1: Update WorkoutQueryService to Use Lap Events

### Overview
Replace the incorrect `workoutActivities` approach with reading lap events from `workoutEvents`.

### Changes Required:

#### 1. Update mapWorkoutToDomainModel
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/WorkoutQueryService.swift`

Replace lines 35-47:

```swift
private func mapWorkoutToDomainModel(_ workout: HKWorkout) -> WorkoutDomainModel {
    // Extract lap events from workoutEvents
    let lapEvents = (workout.workoutEvents ?? [])
        .filter { $0.type == .lap }
        .sorted { $0.dateInterval.start < $1.dateInterval.start }

    let splits = lapEvents.enumerated().map { index, event in
        WorkoutSplit(
            id: "\(workout.uuid)-lap-\(index + 1)",
            index: index + 1,
            startDate: event.dateInterval.start,
            endDate: event.dateInterval.end,
            duration: event.dateInterval.duration,
            distance: nil, // Lap events don't include distance directly
            averageHeartRate: nil, // Would require separate query
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
        totalDistance: totalDistance(for: workout),
        averageHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
        maxHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?.maximumQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
        averageSpeed: nil,
        splits: splits
    )
}

private func totalDistance(for workout: HKWorkout) -> Double? {
    // Try different distance types based on workout
    if let distance = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meter()) {
        return distance
    }
    if let distance = workout.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()?.doubleValue(for: .meter()) {
        return distance
    }
    if let distance = workout.statistics(for: HKQuantityType(.distanceSwimming))?.sumQuantity()?.doubleValue(for: .meter()) {
        return distance
    }
    return nil
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Bike ride with manual laps shows correct lap count
- [ ] Lap durations match what was recorded
- [ ] Workouts without manual laps show 0 splits (correct behavior)

---

## Phase 2: (Optional) Add Per-Lap Statistics

### Overview
If per-lap distance and heart rate are needed, we can query samples for each lap's time range. This requires async queries and is more complex.

### Changes Required:

#### 1. Create LapStatisticsService
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/LapStatisticsService.swift`

```swift
import Foundation
import HealthKit

struct LapStatisticsService: Sendable {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    /// Query statistics for a specific time range within a workout
    func queryStatistics(
        for workout: HKWorkout,
        from startDate: Date,
        to endDate: Date
    ) async throws -> LapStatistics {
        async let distance = queryDistance(for: workout, from: startDate, to: endDate)
        async let heartRate = queryHeartRate(from: startDate, to: endDate)

        return try await LapStatistics(
            distance: distance,
            averageHeartRate: heartRate
        )
    }

    private func queryDistance(
        for workout: HKWorkout,
        from startDate: Date,
        to endDate: Date
    ) async throws -> Double? {
        let distanceType = distanceQuantityType(for: workout.workoutActivityType)
        guard let quantityType = distanceType else { return nil }

        // Query samples in time range that are associated with this workout
        let workoutPredicate = HKQuery.predicateForObjects(from: workout)
        let timePredicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [workoutPredicate, timePredicate])

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let distance = statistics?.sumQuantity()?.doubleValue(for: .meter())
                continuation.resume(returning: distance)
            }
            healthStore.execute(query)
        }
    }

    private func queryHeartRate(from startDate: Date, to endDate: Date) async throws -> Double? {
        let heartRateType = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: heartRateType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let avgHR = statistics?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                continuation.resume(returning: avgHR)
            }
            healthStore.execute(query)
        }
    }

    private func distanceQuantityType(for activityType: HKWorkoutActivityType) -> HKQuantityType? {
        switch activityType {
        case .running, .walking, .hiking:
            return HKQuantityType(.distanceWalkingRunning)
        case .cycling:
            return HKQuantityType(.distanceCycling)
        case .swimming:
            return HKQuantityType(.distanceSwimming)
        default:
            return HKQuantityType(.distanceWalkingRunning)
        }
    }
}

struct LapStatistics: Sendable {
    let distance: Double?
    let averageHeartRate: Double?
}
```

#### 2. Update WorkoutQueryService to Use LapStatisticsService
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/WorkoutQueryService.swift`

This would require making `mapWorkoutToDomainModel` async and querying statistics for each lap. Only implement if per-lap stats are needed.

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Per-lap distance shows reasonable values
- [ ] Per-lap heart rate shows average for that time period

---

## Testing Strategy

### Manual Testing Steps:
1. Record a workout with the Apple Workout app
2. Press the lap button multiple times during the workout
3. Finish and save the workout
4. Open UnoHealthKit app
5. Verify the workout shows the correct number of laps
6. Verify lap durations match what you recorded

### Edge Cases:
- Workout with no manual laps (should show 0 splits)
- Workout with 1 lap (edge case)
- Workout with many laps (10+)

## References

- [HKWorkoutEvent](https://developer.apple.com/documentation/healthkit/hkworkoutevent)
- [HKWorkoutEventType.lap](https://developer.apple.com/documentation/healthkit/hkworkouteventtype/lap)
- [workout.workoutEvents](https://developer.apple.com/documentation/healthkit/hkworkout/1615424-workoutevents)
- [WWDC 2017: What's New in Health](https://asciiwwdc.com/2017/sessions/221)

# HealthKit Workout Events (Laps & Segments) Implementation Plan

## Overview

Update the HealthKit example app to properly model and display both lap and segment workout events using a discriminated union pattern consistent with the rest of the Uno architecture.

## Current State Analysis

### The Problem
- `WorkoutSplit` at `HealthDomainModels.swift:41-50` is a flat struct with no event type distinction
- `WorkoutQueryService.swift:44-45` only filters for `.segment` events, ignoring `.lap` events
- Apple Workout app records manual lap button presses as `.segment` (type 7), but other apps may use `.lap` (type 3)
- UI says "laps" but we're actually showing segments

### Key Discoveries
- `TimelineEntry` at `HealthDomainModels.swift:6-23` provides the pattern for discriminated unions with computed properties
- Project uses `*DomainModel` suffix for domain entities
- View state models use `*ListItem` suffix with formatted strings
- All domain models conform to `Identifiable, Equatable, Sendable`

## Desired End State

A workout event system that:
1. Models both `.lap` and `.segment` HealthKit events as a discriminated union
2. Displays the correct event type in the UI ("3 laps" vs "6 segments" vs "2 laps, 4 segments")
3. Follows existing patterns (`TimelineEntry`, `TimelineListItem`) for consistency
4. Preserves all event data (duration, timestamps) for both types

### Verification:
- Workouts with lap events show "X laps"
- Workouts with segment events show "X segments"
- Workouts with both show combined count with breakdown
- Build succeeds with no new warnings

## What We're NOT Doing

- Per-event statistics (distance, heart rate) - future enhancement
- Marker events (`.marker` type 4) - not user-facing lap data
- Pause/resume events - already handled separately
- Detailed event list view - just showing count for now

---

## Phase 1: Update Domain Models

### Overview
Create `WorkoutEvent` discriminated union and supporting types, replacing the flat `WorkoutSplit` struct.

### Changes Required:

#### 1. Replace WorkoutSplit with WorkoutEvent union
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Models/HealthDomainModels.swift`

Replace `WorkoutSplit` struct (lines 41-50) with:

```swift
// MARK: - Workout Event (Union of Lap or Segment)

enum WorkoutEvent: Identifiable, Equatable, Sendable {
    case lap(WorkoutLap)
    case segment(WorkoutSegment)

    var id: String {
        switch self {
        case .lap(let lap): return "lap-\(lap.id)"
        case .segment(let segment): return "segment-\(segment.id)"
        }
    }

    var index: Int {
        switch self {
        case .lap(let lap): return lap.index
        case .segment(let segment): return segment.index
        }
    }

    var startDate: Date {
        switch self {
        case .lap(let lap): return lap.startDate
        case .segment(let segment): return segment.startDate
        }
    }

    var endDate: Date {
        switch self {
        case .lap(let lap): return lap.endDate
        case .segment(let segment): return segment.endDate
        }
    }

    var duration: TimeInterval {
        switch self {
        case .lap(let lap): return lap.duration
        case .segment(let segment): return segment.duration
        }
    }
}

struct WorkoutLap: Identifiable, Equatable, Sendable {
    let id: String
    let index: Int
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
}

struct WorkoutSegment: Identifiable, Equatable, Sendable {
    let id: String
    let index: Int
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
}
```

#### 2. Update WorkoutDomainModel
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Models/HealthDomainModels.swift`

Change line 38 from `splits` to `events`:

```swift
struct WorkoutDomainModel: Identifiable, Equatable, Sendable {
    let id: AnyHashable
    let workoutType: HKWorkoutActivityType
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let totalEnergyBurned: Double?
    let totalDistance: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let averageSpeed: Double?
    let events: [WorkoutEvent]  // Changed from splits: [WorkoutSplit]
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 2: Update WorkoutQueryService

### Overview
Filter for both `.lap` and `.segment` event types and map to the appropriate `WorkoutEvent` case.

### Changes Required:

#### 1. Update mapWorkoutToDomainModel
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/WorkoutQueryService.swift`

Replace the event filtering and mapping logic (lines 43-62):

```swift
private func mapWorkoutToDomainModel(_ workout: HKWorkout) -> WorkoutDomainModel {
    let allEvents = workout.workoutEvents ?? []
    print("[WorkoutQueryService] Workout \(workout.uuid) has \(allEvents.count) total events")

    for event in allEvents {
        print("[WorkoutQueryService]   Event: \(eventTypeName(event.type)) (raw=\(event.type.rawValue)), duration: \(event.dateInterval.duration)s")
    }

    // Filter for lap and segment events
    let relevantEvents = allEvents
        .filter { $0.type == .lap || $0.type == .segment }
        .sorted { $0.dateInterval.start < $1.dateInterval.start }

    let lapCount = relevantEvents.filter { $0.type == .lap }.count
    let segmentCount = relevantEvents.filter { $0.type == .segment }.count
    print("[WorkoutQueryService] Found \(lapCount) laps, \(segmentCount) segments")

    let events: [WorkoutEvent] = relevantEvents.enumerated().map { index, hkEvent in
        let eventIndex = index + 1
        let id = "\(workout.uuid)-\(eventTypeName(hkEvent.type))-\(eventIndex)"

        switch hkEvent.type {
        case .lap:
            return .lap(WorkoutLap(
                id: id,
                index: eventIndex,
                startDate: hkEvent.dateInterval.start,
                endDate: hkEvent.dateInterval.end,
                duration: hkEvent.dateInterval.duration
            ))
        case .segment:
            return .segment(WorkoutSegment(
                id: id,
                index: eventIndex,
                startDate: hkEvent.dateInterval.start,
                endDate: hkEvent.dateInterval.end,
                duration: hkEvent.dateInterval.duration
            ))
        default:
            // Should not reach here due to filter, but handle gracefully
            return .segment(WorkoutSegment(
                id: id,
                index: eventIndex,
                startDate: hkEvent.dateInterval.start,
                endDate: hkEvent.dateInterval.end,
                duration: hkEvent.dateInterval.duration
            ))
        }
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
        events: events
    )
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 3: Update View State Models

### Overview
Add event summary to `WorkoutListItem` for displaying lap/segment counts in the UI.

### Changes Required:

#### 1. Add WorkoutEventSummary struct
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewState.swift`

Add after `WorkoutListItem` struct:

```swift
struct WorkoutEventSummary: Equatable {
    let lapCount: Int
    let segmentCount: Int

    var displayText: String {
        switch (lapCount, segmentCount) {
        case (0, 0):
            return ""
        case (let laps, 0):
            return "\(laps) \(laps == 1 ? "lap" : "laps")"
        case (0, let segments):
            return "\(segments) \(segments == 1 ? "segment" : "segments")"
        case (let laps, let segments):
            return "\(laps) \(laps == 1 ? "lap" : "laps"), \(segments) \(segments == 1 ? "segment" : "segments")"
        }
    }

    var totalCount: Int {
        lapCount + segmentCount
    }
}
```

#### 2. Update WorkoutListItem
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewState.swift`

Replace `splitsCount: Int` with `eventSummary: WorkoutEventSummary`:

```swift
struct WorkoutListItem: Identifiable, Equatable {
    let id: String
    let workoutType: String
    let workoutIcon: String
    let startTime: String
    let duration: String
    let calories: String?
    let distance: String?
    let heartRate: String?
    let eventSummary: WorkoutEventSummary  // Changed from splitsCount: Int
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 4: Update TimelineViewStateReducer

### Overview
Map domain `WorkoutEvent` array to `WorkoutEventSummary` for view state.

### Changes Required:

#### 1. Update mapWorkout function
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewStateReducer.swift`

Update the `mapWorkout` function to create `WorkoutEventSummary`:

```swift
private func mapWorkout(_ workout: WorkoutDomainModel) -> WorkoutListItem {
    let lapCount = workout.events.filter {
        if case .lap = $0 { return true }
        return false
    }.count

    let segmentCount = workout.events.filter {
        if case .segment = $0 { return true }
        return false
    }.count

    print("[ViewStateReducer] Mapping workout \(workout.id) with \(lapCount) laps, \(segmentCount) segments")

    let item = WorkoutListItem(
        id: String(describing: workout.id),
        workoutType: workoutTypeName(workout.workoutType),
        workoutIcon: workoutTypeIcon(workout.workoutType),
        startTime: workout.startDate.formatted(.dateTime.hour().minute()),
        duration: formatDuration(workout.duration),
        calories: workout.totalEnergyBurned.map { "\(Int($0)) kcal" },
        distance: workout.totalDistance.map { formatDistance($0) },
        heartRate: workout.averageHeartRate.map { "\(Int($0)) bpm avg" },
        eventSummary: WorkoutEventSummary(lapCount: lapCount, segmentCount: segmentCount)
    )
    print("[ViewStateReducer] Created WorkoutListItem with eventSummary: \(item.eventSummary.displayText)")
    return item
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 5: Update WorkoutCell UI

### Overview
Display event summary text from the view model.

### Changes Required:

#### 1. Update WorkoutCell
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/Cells/WorkoutCell.swift`

Update the events display section:

```swift
if workout.eventSummary.totalCount > 0 {
    HStack {
        Image(systemName: "flag.fill")
            .foregroundStyle(.green)
        Text(workout.eventSummary.displayText)
            .foregroundStyle(.secondary)
    }
    .font(.caption)
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Workouts with segments show "X segments"
- [ ] Workouts with laps show "X laps"
- [ ] Workouts with both show "X laps, Y segments"
- [ ] Workouts with no events show nothing (no empty row)

---

## Phase 6: Update TimelineInteractor Logging

### Overview
Update logging to reflect new `events` property name.

### Changes Required:

#### 1. Update logging
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineInteractor.swift`

Update the workout logging (around line 58-62):

```swift
for workout in workoutResults {
    let lapCount = workout.events.filter { if case .lap = $0 { return true }; return false }.count
    let segmentCount = workout.events.filter { if case .segment = $0 { return true }; return false }.count
    print("[TimelineInteractor] Workout: \(workout.workoutType.rawValue) on \(workout.startDate), events: \(lapCount) laps, \(segmentCount) segments")
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Testing Strategy

### Manual Testing Steps:
1. Run app on device with workout data containing segment events
2. Verify segments display correctly (e.g., "6 segments")
3. If possible, record a workout using an app that creates `.lap` events
4. Verify laps display correctly
5. Verify console logging shows correct event type breakdown

### Edge Cases:
- Workout with no events (should show nothing)
- Workout with only laps
- Workout with only segments
- Workout with mix of both (if possible to create)

## References

- Pattern reference: `TimelineEntry` at `HealthDomainModels.swift:6-23`
- HKWorkoutEventType documentation: `.lap` (rawValue 3), `.segment` (rawValue 7)
- Previous plan: `thoughts/shared/plans/2025-12-31_healthkit_distance_splits.md`

# HealthKit Workout Detail View Implementation Plan

## Overview

Enhance the HealthKit example app to display real activity names, collect additional workout statistics (speed, power, cadence), and add a detail view accessible via navigation push from workout cards. The detail view renders statistics in a big, bold, and colorful UI.

## Current State Analysis

### Existing Implementation
- `WorkoutDomainModel` at `HealthDomainModels.swift:27-39` stores basic workout data including events (laps/segments)
- `WorkoutQueryService.swift:35-96` queries workouts and extracts events, but:
  - Uses hardcoded activity name mapping (`workoutTypeName` in reducer)
  - `averageSpeed` is always `nil` (line 93)
  - No power or cadence statistics are collected
- `WorkoutListItem` at `TimelineViewState.swift:32-42` has basic display fields
- `WorkoutCell.swift:3-64` displays workout summary without navigation
- `TimelineView.swift:53-60` renders cells directly without `NavigationLink`

### Key Discoveries
- HealthKit provides `statistics(for:)` on `HKWorkout` for quantity types like:
  - `.runningSpeed` / `.cyclingSpeed` for average speed
  - `.runningPower` / `.cyclingPower` for power
  - `.runningCadence` / `.cyclingCadence` / `.swimmingStrokeCount` for cadence
- Real activity name can be obtained via comprehensive `HKWorkoutActivityType` switch
- Navigation pattern: Use `NavigationLink` within list cells to push detail view
- Uno pattern: Detail view creates its own ViewModel with data passed via initializer

## Desired End State

A HealthKit app where:
1. Workout cards display the real activity name (e.g., "Traditional Strength Training" not just "Strength")
2. Additional statistics are collected and stored: average speed, average power, average cadence
3. Tapping a workout card navigates to a detail view
4. Detail view shows all workout statistics in a big, bold, colorful UI with:
   - Large hero section with activity icon and duration
   - Colorful stat cards for each metric
   - Event timeline showing laps/segments with individual durations

### Verification:
- All workout types show human-readable activity names
- Speed, power, cadence display when available (activity-dependent)
- Navigation pushes smoothly to detail view
- Detail view renders with bold typography and vibrant colors
- Back navigation returns to timeline

## What We're NOT Doing

- Creating a separate Interactor for the detail view (stateless display only)
- Adding editing or sharing functionality
- Per-lap statistics (distance, heart rate for each lap)
- Map view or route visualization
- Persistent navigation state management

---

## Phase 1: Expand Domain Model with Additional Statistics

### Overview
Add fields for average speed, average power, average cadence, and custom activity name to the workout domain model.

### Changes Required:

#### 1. Update WorkoutDomainModel
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Models/HealthDomainModels.swift`

Add new optional fields after line 37:

```swift
struct WorkoutDomainModel: Identifiable, Equatable, Sendable {
    let id: AnyHashable
    let workoutType: HKWorkoutActivityType
    let workoutName: String?          // Custom name from HKMetadataKeyWorkoutBrandName (NEW)
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let totalEnergyBurned: Double?
    let totalDistance: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let averageSpeed: Double?         // m/s
    let averagePower: Double?         // watts (NEW)
    let averageCadence: Double?       // steps/min or rpm (NEW)
    let events: [WorkoutEvent]
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 2: Query Additional Statistics from HealthKit

### Overview
Update `WorkoutQueryService` to query speed, power, and cadence statistics from HealthKit.

### Changes Required:

#### 1. Update mapWorkoutToDomainModel
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/WorkoutQueryService.swift`

Replace lines 83-95 (the return statement) with:

```swift
let workoutName = workout.metadata?[HKMetadataKeyWorkoutBrandName] as? String

return WorkoutDomainModel(
    id: workout.uuid,
    workoutType: workout.workoutActivityType,
    workoutName: workoutName,
    startDate: workout.startDate,
    endDate: workout.endDate,
    duration: workout.duration,
    totalEnergyBurned: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
    totalDistance: totalDistance(for: workout),
    averageHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
    maxHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?.maximumQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
    averageSpeed: averageSpeed(for: workout),
    averagePower: averagePower(for: workout),
    averageCadence: averageCadence(for: workout),
    events: events
)
```

#### 2. Add averageSpeed helper
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/WorkoutQueryService.swift`

Add after `totalDistance(for:)`:

```swift
private func averageSpeed(for workout: HKWorkout) -> Double? {
    let speedTypes: [HKQuantityTypeIdentifier] = [.runningSpeed, .cyclingSpeed]
    for identifier in speedTypes {
        if let speed = workout.statistics(for: HKQuantityType(identifier))?.averageQuantity()?.doubleValue(for: HKUnit.meter().unitDivided(by: .second())) {
            return speed
        }
    }
    return nil
}
```

#### 3. Add averagePower helper
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/WorkoutQueryService.swift`

```swift
private func averagePower(for workout: HKWorkout) -> Double? {
    let powerTypes: [HKQuantityTypeIdentifier] = [.runningPower, .cyclingPower]
    for identifier in powerTypes {
        if let power = workout.statistics(for: HKQuantityType(identifier))?.averageQuantity()?.doubleValue(for: .watt()) {
            return power
        }
    }
    return nil
}
```

#### 4. Add averageCadence helper
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/WorkoutQueryService.swift`

```swift
private func averageCadence(for workout: HKWorkout) -> Double? {
    switch workout.workoutActivityType {
    case .running, .walking, .hiking:
        return workout.statistics(for: HKQuantityType(.runningStrideLength))
            .flatMap { _ in
                workout.statistics(for: HKQuantityType(.stepCount))?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
            }
            ?? workout.statistics(for: HKQuantityType(.stepCount))?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
    case .cycling:
        return workout.statistics(for: HKQuantityType(.cyclingCadence))?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
    case .swimming:
        return workout.statistics(for: HKQuantityType(.swimmingStrokeCount))?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
    default:
        return nil
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Running workouts show speed and cadence
- [ ] Cycling workouts show speed, power (if available), and cadence
- [ ] Other workouts gracefully show nil for unavailable stats

---

## Phase 3: Add Real Activity Name Mapping

### Overview
Create a comprehensive activity name mapping that returns the full human-readable activity name.

### Changes Required:

#### 1. Create ActivityNameMapper
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/ActivityNameMapper.swift` (NEW)

```swift
import HealthKit

enum ActivityNameMapper {
    static func displayName(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .americanFootball: return "American Football"
        case .archery: return "Archery"
        case .australianFootball: return "Australian Football"
        case .badminton: return "Badminton"
        case .baseball: return "Baseball"
        case .basketball: return "Basketball"
        case .bowling: return "Bowling"
        case .boxing: return "Boxing"
        case .climbing: return "Climbing"
        case .cricket: return "Cricket"
        case .crossTraining: return "Cross Training"
        case .curling: return "Curling"
        case .cycling: return "Cycling"
        case .dance: return "Dance"
        case .danceInspiredTraining: return "Dance Inspired Training"
        case .elliptical: return "Elliptical"
        case .equestrianSports: return "Equestrian Sports"
        case .fencing: return "Fencing"
        case .fishing: return "Fishing"
        case .functionalStrengthTraining: return "Functional Strength Training"
        case .golf: return "Golf"
        case .gymnastics: return "Gymnastics"
        case .handball: return "Handball"
        case .hiking: return "Hiking"
        case .hockey: return "Hockey"
        case .hunting: return "Hunting"
        case .lacrosse: return "Lacrosse"
        case .martialArts: return "Martial Arts"
        case .mindAndBody: return "Mind and Body"
        case .mixedMetabolicCardioTraining: return "Mixed Cardio"
        case .paddleSports: return "Paddle Sports"
        case .play: return "Play"
        case .preparationAndRecovery: return "Preparation and Recovery"
        case .racquetball: return "Racquetball"
        case .rowing: return "Rowing"
        case .rugby: return "Rugby"
        case .running: return "Running"
        case .sailing: return "Sailing"
        case .skatingSports: return "Skating"
        case .snowSports: return "Snow Sports"
        case .soccer: return "Soccer"
        case .softball: return "Softball"
        case .squash: return "Squash"
        case .stairClimbing: return "Stair Climbing"
        case .surfingSports: return "Surfing"
        case .swimming: return "Swimming"
        case .tableTennis: return "Table Tennis"
        case .tennis: return "Tennis"
        case .trackAndField: return "Track and Field"
        case .traditionalStrengthTraining: return "Traditional Strength Training"
        case .volleyball: return "Volleyball"
        case .walking: return "Walking"
        case .waterFitness: return "Water Fitness"
        case .waterPolo: return "Water Polo"
        case .waterSports: return "Water Sports"
        case .wrestling: return "Wrestling"
        case .yoga: return "Yoga"
        case .barre: return "Barre"
        case .coreTraining: return "Core Training"
        case .crossCountrySkiing: return "Cross Country Skiing"
        case .downhillSkiing: return "Downhill Skiing"
        case .flexibility: return "Flexibility"
        case .highIntensityIntervalTraining: return "HIIT"
        case .jumpRope: return "Jump Rope"
        case .kickboxing: return "Kickboxing"
        case .pilates: return "Pilates"
        case .snowboarding: return "Snowboarding"
        case .stairs: return "Stairs"
        case .stepTraining: return "Step Training"
        case .wheelchairWalkPace: return "Wheelchair Walk Pace"
        case .wheelchairRunPace: return "Wheelchair Run Pace"
        case .taiChi: return "Tai Chi"
        case .mixedCardio: return "Mixed Cardio"
        case .handCycling: return "Hand Cycling"
        case .discSports: return "Disc Sports"
        case .fitnessGaming: return "Fitness Gaming"
        case .cardioDance: return "Cardio Dance"
        case .socialDance: return "Social Dance"
        case .pickleball: return "Pickleball"
        case .cooldown: return "Cooldown"
        case .swimBikeRun: return "Triathlon"
        case .transition: return "Transition"
        case .underwaterDiving: return "Underwater Diving"
        @unknown default: return "Workout"
        }
    }

    static func icon(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "figure.run"
        case .cycling, .handCycling: return "figure.outdoor.cycle"
        case .swimming: return "figure.pool.swim"
        case .walking: return "figure.walk"
        case .hiking: return "figure.hiking"
        case .yoga: return "figure.yoga"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "dumbbell.fill"
        case .highIntensityIntervalTraining: return "flame.fill"
        case .dance, .cardioDance, .socialDance, .danceInspiredTraining: return "figure.dance"
        case .coreTraining: return "figure.core.training"
        case .elliptical: return "figure.elliptical"
        case .rowing: return "figure.rower"
        case .stairClimbing, .stairs, .stepTraining: return "figure.stairs"
        case .boxing, .kickboxing: return "figure.boxing"
        case .pilates: return "figure.pilates"
        case .crossTraining, .mixedCardio, .mixedMetabolicCardioTraining: return "figure.mixed.cardio"
        case .basketball: return "figure.basketball"
        case .soccer: return "sportscourt.fill"
        case .tennis, .tableTennis: return "figure.tennis"
        case .golf: return "figure.golf"
        case .baseball, .softball: return "figure.baseball"
        case .americanFootball, .australianFootball, .rugby: return "football.fill"
        case .skiing, .crossCountrySkiing, .downhillSkiing: return "figure.skiing.downhill"
        case .snowboarding: return "figure.snowboarding"
        case .snowSports: return "snowflake"
        case .surfingSports, .waterSports: return "figure.surfing"
        case .climbing: return "figure.climbing"
        case .jumpRope: return "figure.jumprope"
        case .flexibility: return "figure.flexibility"
        case .barre: return "figure.barre"
        case .taiChi: return "figure.taichi"
        case .martialArts: return "figure.martial.arts"
        case .preparationAndRecovery, .cooldown: return "figure.cooldown"
        case .mindAndBody: return "brain.head.profile"
        case .pickleball, .badminton, .squash, .racquetball: return "figure.racquetball"
        case .volleyball: return "volleyball.fill"
        case .hockey: return "figure.hockey"
        case .lacrosse: return "figure.lacrosse"
        case .swimBikeRun: return "figure.open.water.swim"
        case .fitnessGaming: return "gamecontroller.fill"
        default: return "figure.mixed.cardio"
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 4: Create Workout Detail View State Models

### Overview
Create view state models for the workout detail view that support the bold, colorful UI.

### Changes Required:

#### 1. Create WorkoutDetailViewState
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/WorkoutDetail/WorkoutDetailViewState.swift` (NEW)

```swift
import Foundation
import SwiftUI

struct WorkoutDetailViewState: Equatable {
    let header: WorkoutDetailHeader
    let statsGrid: [WorkoutStatCard]
    let events: [WorkoutEventItem]
}

struct WorkoutDetailHeader: Equatable {
    let activityName: String
    let activityIcon: String
    let dateShort: String
    let timeRange: String
    let accentColor: Color
}

struct WorkoutStatCard: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let unit: String
    let color: Color
}

struct WorkoutEventItem: Identifiable, Equatable {
    let id: String
    let index: Int
    let type: String
    let duration: String
    let startTime: String
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 5: Create Workout Detail View State Factory

### Overview
Create a factory that transforms `WorkoutDomainModel` into `WorkoutDetailViewState`. This is a pure transformation, no interactor needed.

### Changes Required:

#### 1. Create WorkoutDetailViewStateFactory
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/WorkoutDetail/WorkoutDetailViewStateFactory.swift` (NEW)

```swift
import Foundation
import HealthKit
import SwiftUI

enum WorkoutDetailViewStateFactory {
    static func make(from workout: WorkoutDomainModel) -> WorkoutDetailViewState {
        WorkoutDetailViewState(
            header: makeHeader(from: workout),
            statsGrid: makeStatsGrid(from: workout),
            events: makeEvents(from: workout)
        )
    }

    private static func makeHeader(from workout: WorkoutDomainModel) -> WorkoutDetailHeader {
        let startTime = workout.startDate.formatted(.dateTime.hour().minute())
        let endTime = workout.endDate.formatted(.dateTime.hour().minute())

        let activityName = workout.workoutName
            ?? ActivityNameMapper.displayName(for: workout.workoutType)

        return WorkoutDetailHeader(
            activityName: activityName,
            activityIcon: ActivityNameMapper.icon(for: workout.workoutType),
            dateShort: workout.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
            timeRange: "\(startTime)–\(endTime)",
            accentColor: accentColor(for: workout.workoutType)
        )
    }

    private static func makeStatsGrid(from workout: WorkoutDomainModel) -> [WorkoutStatCard] {
        var cards: [WorkoutStatCard] = []

        cards.append(WorkoutStatCard(
            id: "duration",
            title: "Workout Time",
            value: formatDuration(workout.duration),
            unit: "",
            color: .green
        ))

        if let distance = workout.totalDistance {
            let miles = distance / 1609.34
            cards.append(WorkoutStatCard(
                id: "distance",
                title: "Distance",
                value: String(format: "%.2f", miles),
                unit: "mi",
                color: .cyan
            ))
        }

        if let calories = workout.totalEnergyBurned {
            cards.append(WorkoutStatCard(
                id: "calories",
                title: "Active Calories",
                value: formatNumber(calories),
                unit: "cal",
                color: .yellow
            ))
        }

        if let avgHR = workout.averageHeartRate {
            cards.append(WorkoutStatCard(
                id: "avgHR",
                title: "Avg. Heart Rate",
                value: "\(Int(avgHR))",
                unit: "bpm",
                color: .red
            ))
        }

        if let speed = workout.averageSpeed {
            let mph = speed * 2.23694
            cards.append(WorkoutStatCard(
                id: "speed",
                title: "Avg. Speed",
                value: String(format: "%.1f", mph),
                unit: "mph",
                color: .cyan
            ))
        }

        if let power = workout.averagePower {
            cards.append(WorkoutStatCard(
                id: "power",
                title: "Avg. Power",
                value: "\(Int(power))",
                unit: "W",
                color: .yellow
            ))
        }

        if let cadence = workout.averageCadence {
            let unit = cadenceUnit(for: workout.workoutType)
            cards.append(WorkoutStatCard(
                id: "cadence",
                title: "Avg. Cadence",
                value: "\(Int(cadence))",
                unit: unit,
                color: .purple
            ))
        }

        if let maxHR = workout.maxHeartRate {
            cards.append(WorkoutStatCard(
                id: "maxHR",
                title: "Max Heart Rate",
                value: "\(Int(maxHR))",
                unit: "bpm",
                color: .red
            ))
        }

        return cards
    }

    private static func makeEvents(from workout: WorkoutDomainModel) -> [WorkoutEventItem] {
        workout.events.map { event in
            let typeName: String
            switch event {
            case .lap: typeName = "Lap"
            case .segment: typeName = "Segment"
            }

            return WorkoutEventItem(
                id: event.id,
                index: event.index,
                type: typeName,
                duration: formatDuration(event.duration),
                startTime: event.startDate.formatted(.dateTime.hour().minute().second())
            )
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    private static func formatNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    private static func accentColor(for type: HKWorkoutActivityType) -> Color {
        switch type {
        case .running: return .orange
        case .cycling, .handCycling: return .green
        case .swimming: return .blue
        case .walking, .hiking: return .teal
        case .yoga, .pilates, .flexibility: return .purple
        case .functionalStrengthTraining, .traditionalStrengthTraining: return .red
        case .highIntensityIntervalTraining: return .pink
        case .dance, .cardioDance, .socialDance: return .indigo
        default: return .orange
        }
    }

    private static func cadenceUnit(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .cycling, .handCycling: return "rpm"
        case .swimming: return "spm"
        default: return "spm"
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 6: Create Workout Detail View

### Overview
Create a detail view mimicking Apple's Fitness app design with a header section, 2-column stats grid with colored values, and a splits table.

### Changes Required:

#### 1. Create WorkoutDetailView
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/WorkoutDetailView.swift` (NEW)

```swift
import SwiftUI

struct WorkoutDetailView: View {
    let viewState: WorkoutDetailViewState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                workoutDetailsSection
                if !viewState.events.isEmpty {
                    splitsSection
                }
            }
            .padding()
        }
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(viewState.header.dateShort)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
        }
    }

    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(viewState.header.accentColor)
                    .frame(width: 64, height: 64)

                Image(systemName: viewState.header.activityIcon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(viewState.header.activityName)
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text(viewState.header.timeRange)
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }

            Spacer()
        }
    }

    private var workoutDetailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Workout Details")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Image(systemName: "chevron.right")
                    .font(.title3.bold())
                    .foregroundStyle(.gray)
            }

            VStack(spacing: 0) {
                let rows = viewState.statsGrid.chunked(into: 2)
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowStats in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(rowStats) { stat in
                            StatCell(stat: stat)
                            if stat.id != rowStats.last?.id {
                                Spacer()
                            }
                        }
                        if rowStats.count == 1 {
                            Spacer()
                        }
                    }
                    .padding(.vertical, 12)

                    if rowIndex < rows.count - 1 {
                        Divider()
                            .background(Color.gray.opacity(0.3))
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray6).opacity(0.15))
            )
        }
    }

    private var splitsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Splits")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Image(systemName: "chevron.right")
                    .font(.title3.bold())
                    .foregroundStyle(.gray)
            }

            VStack(spacing: 0) {
                HStack {
                    Text("")
                        .frame(width: 30)
                    Text("Time")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Duration")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.gray)
                .padding(.horizontal)
                .padding(.bottom, 8)

                ForEach(viewState.events) { event in
                    SplitRow(event: event)
                    if event.id != viewState.events.last?.id {
                        Divider()
                            .background(Color.gray.opacity(0.3))
                    }
                }
            }
            .padding(.vertical)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray6).opacity(0.15))
            )
        }
    }
}

struct StatCell: View {
    let stat: WorkoutStatCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.title)
                .font(.subheadline)
                .foregroundStyle(.gray)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(stat.value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(stat.color)
                Text(stat.unit.uppercased())
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(stat.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SplitRow: View {
    let event: WorkoutEventItem

    var body: some View {
        HStack {
            Text("\(event.index)")
                .font(.body)
                .foregroundStyle(.gray)
                .frame(width: 30, alignment: .leading)

            Text(event.startTime)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(event.duration)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 7: Update WorkoutListItem and ViewStateReducer

### Overview
Update `WorkoutListItem` to include the pre-computed `WorkoutDetailViewState` for navigation. The transformation happens in the reducer, keeping domain models out of the view layer.

### Changes Required:

#### 1. Update WorkoutListItem
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewState.swift`

Add `detailViewState` field to `WorkoutListItem` (pre-computed in reducer):

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
    let eventSummary: WorkoutEventSummary
    let detailViewState: WorkoutDetailViewState
}
```

#### 2. Update TimelineViewStateReducer mapWorkout
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewStateReducer.swift`

Replace `mapWorkout` function (lines 65-91) to use `ActivityNameMapper` and pre-compute detail view state:

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

    let activityName = workout.workoutName
        ?? ActivityNameMapper.displayName(for: workout.workoutType)

    return WorkoutListItem(
        id: String(describing: workout.id),
        workoutType: activityName,
        workoutIcon: ActivityNameMapper.icon(for: workout.workoutType),
        startTime: workout.startDate.formatted(.dateTime.hour().minute()),
        duration: formatDuration(workout.duration),
        calories: workout.totalEnergyBurned.map { "\(Int($0)) kcal" },
        distance: workout.totalDistance.map { formatDistance($0) },
        heartRate: workout.averageHeartRate.map { "\(Int($0)) bpm avg" },
        eventSummary: WorkoutEventSummary(lapCount: lapCount, segmentCount: segmentCount),
        detailViewState: WorkoutDetailViewStateFactory.make(from: workout)
    )
}
```

#### 3. Remove old workoutTypeName and workoutTypeIcon functions
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewStateReducer.swift`

Delete the `workoutTypeName` function (lines 111-123) and `workoutTypeIcon` function (lines 125-137) as they are now replaced by `ActivityNameMapper`.

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 8: Add Navigation to TimelineView

### Overview
Wrap workout cells in `NavigationLink` to enable navigation to the detail view using the pre-computed view state.

### Changes Required:

#### 1. Update TimelineView timelineList
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/TimelineView.swift`

Replace the `timelineList` function (lines 49-68):

```swift
private func timelineList(_ content: TimelineListContent) -> some View {
    List {
        ForEach(content.sections) { section in
            Section(section.title) {
                ForEach(section.items) { item in
                    switch item {
                    case .workout(let workout):
                        NavigationLink {
                            WorkoutDetailView(viewState: workout.detailViewState)
                        } label: {
                            WorkoutCell(workout: workout)
                        }
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
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Tapping workout cell navigates to detail view
- [ ] Detail view shows all statistics with bold, colorful UI
- [ ] Back button returns to timeline
- [ ] Events section shows laps/segments with individual durations
- [ ] Activity names are full names (e.g., "Traditional Strength Training")

---

## Phase 9: Update RealHealthKitReader to Request Additional Permissions

### Overview
Add permissions for the new data types being queried (speed, power, cadence).

### Changes Required:

#### 1. Update requiredTypes
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Services/RealHealthKitReader.swift`

Add new quantity types to the `requiredTypes` set:

```swift
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
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] App requests permission for new data types on first launch
- [ ] New statistics display correctly after permissions granted

---

## Testing Strategy

### Unit Tests:
- Test `ActivityNameMapper.displayName(for:)` returns expected strings
- Test `ActivityNameMapper.icon(for:)` returns valid SF Symbol names
- Test `WorkoutDetailViewStateFactory.make(from:)` creates correct view state

### Integration Tests:
- Test navigation from timeline to detail view
- Test detail view state matches domain model data

### Manual Testing Steps:
1. Build and run on device with HealthKit data
2. Grant all permissions when prompted
3. Verify workout cells show full activity names (e.g., "Traditional Strength Training")
4. Tap a workout cell
5. Verify detail view appears with navigation animation
6. Verify header shows large duration and activity icon
7. Verify stat cards show available metrics (varies by activity type)
8. Verify events section shows laps/segments if present
9. Tap back button to return to timeline
10. Verify different activity types show different accent colors

### Edge Cases:
- Workout with no optional statistics (should show only available cards)
- Workout with no events (events section should be hidden)
- Very long workout duration formatting
- Very short lap/segment durations

## Performance Considerations

- Domain model is passed directly to detail view (no additional HealthKit queries)
- ViewStateFactory is pure transformation, runs synchronously
- LazyVGrid ensures efficient rendering of stat cards
- No unnecessary re-renders due to Equatable conformance

## References

- [HKWorkoutActivityType](https://developer.apple.com/documentation/healthkit/hkworkoutactivitytype)
- [HKQuantityTypeIdentifier](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier)
- [Getting activity name through HKWorkoutActivityType](https://medium.com/fantageek/getting-activity-name-through-hkworkoutactivitytype-in-healthkit-51109e022c33)
- Existing patterns: `TimelineView.swift`, `TimelineViewStateReducer.swift`
- Previous plans: `thoughts/shared/plans/2025-12-30_healthkit_example_app.md`

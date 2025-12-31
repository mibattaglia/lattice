# HealthKit Recovery Detail View Implementation Plan

## Overview

Add a detail view for recovery entries in the HealthKit example app. When users tap a recovery cell, they navigate to a detail view that displays sleep and vitals data in a big, bold, colorful UI matching the workout detail view style.

## Current State Analysis

### Existing Implementation
- `RecoveryDomainModel` at `HealthDomainModels.swift:140-145` stores sleep and vitals data
- `SleepData` includes start/end dates, total duration, and sleep stages (awake, REM, core, deep)
- `VitalsData` includes resting heart rate, HRV, and respiratory rate
- `RecoveryCell.swift:3-81` displays recovery summary with sleep stages bar and vitals
- `TimelineView.swift:99-100` renders `RecoveryCell` without navigation (unlike workout cells)
- `RecoveryListItem` at `TimelineViewState.swift:67-74` has basic display fields but no detail view state

### Key Observations
- Workout detail pattern: `WorkoutListItem` includes pre-computed `detailViewState` field
- Factory pattern: `WorkoutDetailViewStateFactory` transforms domain model to view state
- Navigation: `NavigationLink` wraps workout cells to push detail view
- Recovery has rich data that could fill a compelling detail view

## Desired End State

A HealthKit app where:
1. Tapping a recovery cell navigates to a detail view
2. Detail view shows sleep data in a big, bold, colorful UI with:
   - Header with moon icon, date, and bed/wake times
   - Large total sleep duration display
   - Sleep stages breakdown as colorful stat cards with percentages
   - Visual sleep stages timeline bar
3. Vitals section with large colorful cards for:
   - Resting heart rate
   - Heart rate variability (HRV)
   - Respiratory rate
4. Back navigation returns to timeline

### Verification:
- Navigation pushes smoothly to detail view
- Detail view renders with bold typography and vibrant colors
- Sleep stages show both duration and percentage
- Vitals display when available (gracefully hidden when nil)
- Back navigation returns to timeline

## What We're NOT Doing

- Creating a separate Interactor for the detail view (stateless display only)
- Adding sleep quality scoring or recommendations
- Per-night comparisons or trends
- Sleep sounds or environmental data
- Editing or sharing functionality

---

## Phase 1: Create Recovery Detail View State Models

### Overview
Create view state models for the recovery detail view that support the bold, colorful UI.

### Changes Required:

#### 1. Create RecoveryDetailViewState
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/RecoveryDetail/RecoveryDetailViewState.swift` (NEW)

```swift
import Foundation
import SwiftUI

struct RecoveryDetailViewState: Equatable {
    let header: RecoveryDetailHeader
    let sleepSummary: SleepSummaryCard?
    let sleepStages: [SleepStageCard]
    let vitals: [VitalStatCard]
}

struct RecoveryDetailHeader: Equatable {
    let dateShort: String
    let dateFull: String
    let accentColor: Color
}

struct SleepSummaryCard: Equatable {
    let totalSleep: String
    let bedTime: String
    let wakeTime: String
    let timeInBed: String
}

struct SleepStageCard: Identifiable, Equatable {
    let id: String
    let stageName: String
    let duration: String
    let percentage: String
    let color: Color
    let fractionOfTotal: Double
}

struct VitalStatCard: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let unit: String
    let color: Color
    let icon: String
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 2: Create Recovery Detail View State Factory

### Overview
Create a factory that transforms `RecoveryDomainModel` into `RecoveryDetailViewState`. This is a pure transformation, no interactor needed.

### Changes Required:

#### 1. Create RecoveryDetailViewStateFactory
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/RecoveryDetail/RecoveryDetailViewStateFactory.swift` (NEW)

```swift
import Foundation
import SwiftUI

enum RecoveryDetailViewStateFactory {
    static func make(from recovery: RecoveryDomainModel) -> RecoveryDetailViewState {
        RecoveryDetailViewState(
            header: makeHeader(from: recovery),
            sleepSummary: makeSleepSummary(from: recovery.sleep),
            sleepStages: makeSleepStages(from: recovery.sleep),
            vitals: makeVitals(from: recovery.vitals)
        )
    }

    private static func makeHeader(from recovery: RecoveryDomainModel) -> RecoveryDetailHeader {
        RecoveryDetailHeader(
            dateShort: recovery.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
            dateFull: recovery.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()),
            accentColor: .indigo
        )
    }

    private static func makeSleepSummary(from sleep: SleepData?) -> SleepSummaryCard? {
        guard let sleep = sleep else { return nil }

        let bedTime = sleep.startDate.formatted(.dateTime.hour().minute())
        let wakeTime = sleep.endDate.formatted(.dateTime.hour().minute())
        let timeInBed = sleep.endDate.timeIntervalSince(sleep.startDate)

        return SleepSummaryCard(
            totalSleep: formatDurationLong(sleep.totalSleepDuration),
            bedTime: bedTime,
            wakeTime: wakeTime,
            timeInBed: formatDurationLong(timeInBed)
        )
    }

    private static func makeSleepStages(from sleep: SleepData?) -> [SleepStageCard] {
        guard let sleep = sleep else { return [] }

        let total = sleep.totalSleepDuration
        guard total > 0 else { return [] }

        return [
            SleepStageCard(
                id: "awake",
                stageName: "Awake",
                duration: formatDurationShort(sleep.stages.awake),
                percentage: formatPercentage(sleep.stages.awake, of: total),
                color: .orange,
                fractionOfTotal: sleep.stages.awake / total
            ),
            SleepStageCard(
                id: "rem",
                stageName: "REM",
                duration: formatDurationShort(sleep.stages.rem),
                percentage: formatPercentage(sleep.stages.rem, of: total),
                color: .cyan,
                fractionOfTotal: sleep.stages.rem / total
            ),
            SleepStageCard(
                id: "core",
                stageName: "Core",
                duration: formatDurationShort(sleep.stages.core),
                percentage: formatPercentage(sleep.stages.core, of: total),
                color: .blue,
                fractionOfTotal: sleep.stages.core / total
            ),
            SleepStageCard(
                id: "deep",
                stageName: "Deep",
                duration: formatDurationShort(sleep.stages.deep),
                percentage: formatPercentage(sleep.stages.deep, of: total),
                color: .indigo,
                fractionOfTotal: sleep.stages.deep / total
            )
        ]
    }

    private static func makeVitals(from vitals: VitalsData?) -> [VitalStatCard] {
        guard let vitals = vitals else { return [] }

        var cards: [VitalStatCard] = []

        if let rhr = vitals.restingHeartRate {
            cards.append(VitalStatCard(
                id: "rhr",
                title: "Resting Heart Rate",
                value: "\(Int(rhr))",
                unit: "bpm",
                color: .red,
                icon: "heart.fill"
            ))
        }

        if let hrv = vitals.heartRateVariability {
            cards.append(VitalStatCard(
                id: "hrv",
                title: "Heart Rate Variability",
                value: "\(Int(hrv))",
                unit: "ms",
                color: .green,
                icon: "waveform.path.ecg"
            ))
        }

        if let respRate = vitals.respiratoryRate {
            cards.append(VitalStatCard(
                id: "respRate",
                title: "Respiratory Rate",
                value: String(format: "%.1f", respRate),
                unit: "br/min",
                color: .cyan,
                icon: "lungs.fill"
            ))
        }

        return cards
    }

    private static func formatDurationLong(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private static func formatDurationShort(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private static func formatPercentage(_ value: TimeInterval, of total: TimeInterval) -> String {
        guard total > 0 else { return "0%" }
        let percentage = (value / total) * 100
        return "\(Int(percentage))%"
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 3: Create Recovery Detail View

### Overview
Create a detail view mimicking Apple's Health app sleep design with a header section, sleep summary, sleep stages visualization, and vitals cards.

### Changes Required:

#### 1. Create RecoveryDetailView
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/RecoveryDetailView.swift` (NEW)

```swift
import SwiftUI

struct RecoveryDetailView: View {
    let viewState: RecoveryDetailViewState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                if viewState.sleepSummary != nil {
                    sleepSection
                }
                if !viewState.sleepStages.isEmpty {
                    sleepStagesSection
                }
                if !viewState.vitals.isEmpty {
                    vitalsSection
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

                Image(systemName: "bed.double.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Recovery")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text(viewState.header.dateFull)
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }

            Spacer()
        }
    }

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sleep")
                .font(.title2.bold())
                .foregroundStyle(.white)

            if let summary = viewState.sleepSummary {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total Sleep")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                            Text(summary.totalSleep)
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .foregroundStyle(.indigo)
                        }
                        Spacer()
                    }

                    HStack(spacing: 24) {
                        sleepTimeView(label: "Bedtime", time: summary.bedTime, icon: "moon.fill")
                        sleepTimeView(label: "Wake Up", time: summary.wakeTime, icon: "sun.max.fill")
                        sleepTimeView(label: "In Bed", time: summary.timeInBed, icon: "bed.double.fill")
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.systemGray6).opacity(0.15))
                )
            }
        }
    }

    private func sleepTimeView(label: String, time: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.gray)
            Text(time)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private var sleepStagesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sleep Stages")
                .font(.title2.bold())
                .foregroundStyle(.white)

            VStack(spacing: 12) {
                sleepStagesBar

                VStack(spacing: 0) {
                    ForEach(Array(viewState.sleepStages.enumerated()), id: \.element.id) { index, stage in
                        SleepStageRow(stage: stage)
                        if index < viewState.sleepStages.count - 1 {
                            Divider()
                                .background(Color.gray.opacity(0.3))
                        }
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

    private var sleepStagesBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(viewState.sleepStages) { stage in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(stage.color)
                        .frame(width: max(geometry.size.width * stage.fractionOfTotal - 2, 0))
                }
            }
        }
        .frame(height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var vitalsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vitals")
                .font(.title2.bold())
                .foregroundStyle(.white)

            VStack(spacing: 0) {
                ForEach(Array(viewState.vitals.enumerated()), id: \.element.id) { index, vital in
                    VitalRow(vital: vital)
                    if index < viewState.vitals.count - 1 {
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
}

private struct SleepStageRow: View {
    let stage: SleepStageCard

    var body: some View {
        HStack {
            Circle()
                .fill(stage.color)
                .frame(width: 12, height: 12)

            Text(stage.stageName)
                .font(.body)
                .foregroundStyle(.white)

            Spacer()

            Text(stage.duration)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(stage.color)

            Text(stage.percentage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.gray)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

private struct VitalRow: View {
    let vital: VitalStatCard

    var body: some View {
        HStack {
            Image(systemName: vital.icon)
                .font(.system(size: 20))
                .foregroundStyle(vital.color)
                .frame(width: 32)

            Text(vital.title)
                .font(.body)
                .foregroundStyle(.white)

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(vital.value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(vital.color)
                Text(vital.unit)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(vital.color)
            }
        }
        .padding(.vertical, 12)
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 4: Update RecoveryListItem with Detail View State

### Overview
Update `RecoveryListItem` to include the pre-computed `RecoveryDetailViewState` for navigation, following the same pattern as `WorkoutListItem`.

### Changes Required:

#### 1. Update RecoveryListItem
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewState.swift`

Update `RecoveryListItem` to add `detailViewState` field:

```swift
struct RecoveryListItem: Identifiable, Equatable {
    let id: String
    let totalSleep: String?
    let sleepStages: SleepStagesDisplay?
    let restingHeartRate: String?
    let hrv: String?
    let respiratoryRate: String?
    let detailViewState: RecoveryDetailViewState
}
```

#### 2. Update TimelineViewStateReducer mapRecovery
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/TimelineViewStateReducer.swift`

Update `mapRecovery` function (lines 93-109) to compute detail view state:

```swift
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
        respiratoryRate: recovery.vitals?.respiratoryRate.map { String(format: "%.1f br/min", $0) },
        detailViewState: RecoveryDetailViewStateFactory.make(from: recovery)
    )
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Phase 5: Add Navigation to TimelineView

### Overview
Wrap recovery cells in `NavigationLink` to enable navigation to the detail view, matching the workout cell pattern.

### Changes Required:

#### 1. Update TimelineView sectionView
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/TimelineView.swift`

Update the switch statement in `sectionView` (lines 90-101) to wrap `RecoveryCell` in `NavigationLink`:

```swift
switch item {
case .workout(let workout):
    NavigationLink {
        WorkoutDetailView(viewState: workout.detailViewState)
    } label: {
        WorkoutCell(workout: workout)
    }
    .buttonStyle(.plain)

case .recovery(let recovery):
    NavigationLink {
        RecoveryDetailView(viewState: recovery.detailViewState)
    } label: {
        RecoveryCell(recovery: recovery)
    }
    .buttonStyle(.plain)
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project compiles: `xcodebuild -project Examples/UnoHealthKit/UnoHealthKit.xcodeproj -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Tapping recovery cell navigates to detail view
- [ ] Detail view shows sleep summary with total sleep, bed/wake times
- [ ] Sleep stages section shows visual bar and individual stage cards
- [ ] Vitals section shows available metrics with icons
- [ ] Back button returns to timeline

---

## Testing Strategy

### Unit Tests:
- Test `RecoveryDetailViewStateFactory.make(from:)` creates correct view state
- Test sleep stage percentages sum to approximately 100%
- Test formatting functions for duration and percentage

### Integration Tests:
- Test navigation from timeline to detail view
- Test detail view state matches domain model data

### Manual Testing Steps:
1. Build and run on device with HealthKit data
2. Grant all permissions when prompted
3. Find a recovery entry in the timeline
4. Tap the recovery cell
5. Verify detail view appears with navigation animation
6. Verify header shows "Recovery" with indigo accent and date
7. Verify sleep section shows large total sleep time
8. Verify bed/wake times display correctly
9. Verify sleep stages bar visualizes proportions
10. Verify each sleep stage row shows duration and percentage
11. Verify vitals section shows available metrics
12. Tap back button to return to timeline

### Edge Cases:
- Recovery with no sleep data (should show vitals only)
- Recovery with no vitals data (should show sleep only)
- Recovery with neither sleep nor vitals (header only)
- Very short sleep durations (stage percentages should still be accurate)
- Missing individual vitals (should gracefully hide those cards)

## Performance Considerations

- Domain model is passed directly to detail view (no additional HealthKit queries)
- ViewStateFactory is pure transformation, runs synchronously
- Sleep stages bar uses GeometryReader efficiently
- No unnecessary re-renders due to Equatable conformance

## File Summary

| Phase | File | Action |
|-------|------|--------|
| 1 | `Architecture/RecoveryDetail/RecoveryDetailViewState.swift` | CREATE |
| 2 | `Architecture/RecoveryDetail/RecoveryDetailViewStateFactory.swift` | CREATE |
| 3 | `Views/RecoveryDetailView.swift` | CREATE |
| 4 | `Architecture/Timeline/TimelineViewState.swift` | MODIFY |
| 4 | `Architecture/Timeline/TimelineViewStateReducer.swift` | MODIFY |
| 5 | `Views/TimelineView.swift` | MODIFY |

## References

- Existing patterns: `WorkoutDetailView.swift`, `WorkoutDetailViewStateFactory.swift`
- Domain models: `HealthDomainModels.swift:140-165`
- Current cell: `RecoveryCell.swift`
- Workout detail plan: `thoughts/shared/plans/2025-12-31_healthkit_workout_detail_view.md`

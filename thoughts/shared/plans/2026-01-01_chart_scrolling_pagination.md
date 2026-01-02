# Chart Horizontal Scrolling with Pagination Implementation Plan

## Overview

Add horizontal scrolling with silent bidirectional paginated data fetching to TrendChartCard in the UnoHealthKit app. Charts will display ~14 days of data at a time, with native horizontal scrolling to view more data. When the user scrolls near either boundary (oldest or newest), additional data will be silently prefetched. A rolling window of 42 days maximum keeps memory bounded.

## Current State Analysis

**TrendChartCard.swift**:
- Three chart types (bar, line, area) with identical axis configuration
- Uses `.chartXSelection(value: $selectedDate)` for tap selection (must preserve)
- Fixed `.stride(by: .day, count: 3)` for X-axis labels
- All data points visible simultaneously (no scrolling)

**TrendsInteractor.swift:32**:
- Hardcoded 21-day lookback
- Single-shot data fetch, no pagination

**TrendsDomainState.swift**:
- No tracking of available date ranges
- No loading states for partial data

### Key Discoveries:
- SwiftCharts iOS 17+ provides `.chartScrollableAxes(.horizontal)` for native scrolling
- `.chartXVisibleDomain(length: TimeInterval)` controls visible window size
- `.chartScrollPosition(x: $scrollPosition)` enables scroll position tracking
- `AxisMarks(values: .automatic(desiredCount:))` auto-spaces labels based on visible range
- `.chartXSelection` is compatible with scrollable charts

## Desired End State

After implementation:
1. Each chart scrolls horizontally showing ~14 days at a time
2. User can scroll back in time to view historical data
3. When scroll approaches earliest loaded date, more data loads silently
4. X-axis labels auto-space to avoid crowding
5. Tap selection continues to work during and after scrolling
6. Maximum 42 days of data loaded at any time (rolling window)

### Verification:
- Charts scroll smoothly with native iOS feel
- Scrolling to boundary triggers silent data load
- X-axis shows appropriate number of labels (not crowded)
- Tap selection works correctly on scrolled charts

## What We're NOT Doing

- Pinch-to-zoom functionality (removed from scope)
- Synchronized scroll position across charts (each scrolls independently)
- Loading indicators (silent prefetch only)
- Caching/persistence of historical data

## Implementation Approach

Use native SwiftCharts scrolling APIs with a coordinator pattern:
1. Add scroll state to TrendChartCard
2. Track scroll position to detect when near boundary
3. Propagate "load more" events through the Uno Architecture
4. Merge new data with existing data in domain state
5. ViewStateReducer handles combining data into ChartData

## Phase 1: Enable Chart Scrolling

### Overview
Add horizontal scrolling to TrendChartCard with a fixed 14-day visible window.

### Changes Required:

#### 1. TrendChartCard.swift
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/Charts/TrendChartCard.swift`
**Changes**: Add scrolling modifiers to all three chart types

Add constant for visible days:
```swift
private let visibleDays: TimeInterval = 14 * 24 * 60 * 60 // 14 days in seconds
```

Add to each chart (bar, line, area) after `.chartXSelection(value: $selectedDate)`:
```swift
.chartScrollableAxes(.horizontal)
.chartXVisibleDomain(length: visibleDays)
.chartScrollPosition(initialX: chartData.dataPoints.last?.date ?? Date())
```

Update X-axis configuration from fixed stride to automatic:
```swift
.chartXAxis {
    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
        AxisGridLine()
            .foregroundStyle(Color.gray.opacity(0.3))
        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            .foregroundStyle(.gray)
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Charts scroll horizontally with native iOS feel
- [ ] ~14 days visible at a time
- [ ] X-axis labels don't overlap at any scroll position
- [ ] Initial scroll position shows most recent data (right edge)
- [ ] Tap selection still works on scrolled charts

---

## Phase 2: Add Bidirectional Scroll Position Tracking

### Overview
Track scroll position to detect when user scrolls near either boundary (earliest or latest loaded date), triggering pagination in the appropriate direction.

### Changes Required:

#### 1. TrendChartCard.swift - Add scroll position state and callbacks
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/Charts/TrendChartCard.swift`

Add scroll position state:
```swift
@State private var scrollPosition: Date = Date()
```

Add callback properties for bidirectional pagination:
```swift
var onScrollNearStart: (() -> Void)?
var onScrollNearEnd: (() -> Void)?
```

Add scroll position binding and change handler:
```swift
.chartScrollPosition(x: $scrollPosition)
.onChange(of: scrollPosition) { _, newPosition in
    checkIfNearBoundary(newPosition)
}
```

Add helper to check proximity to both boundaries:
```swift
private func checkIfNearBoundary(_ currentPosition: Date) {
    let calendar = Calendar.current

    // Check proximity to earliest date (scroll left/backward in time)
    if let earliestDate = chartData.dataPoints.first?.date {
        let daysFromStart = calendar.dateComponents([.day], from: earliestDate, to: currentPosition).day ?? 0
        if daysFromStart <= 5 {
            onScrollNearStart?()
        }
    }

    // Check proximity to latest date (scroll right/forward in time)
    if let latestDate = chartData.dataPoints.last?.date {
        let daysFromEnd = calendar.dateComponents([.day], from: currentPosition, to: latestDate).day ?? 0
        if daysFromEnd <= 5 {
            onScrollNearEnd?()
        }
    }
}
```

#### 2. TrendsView.swift - Wire up both callbacks
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/TrendsView.swift`

Update TrendChartCard instantiation to include both callbacks:
```swift
TrendChartCard(
    chartData: content.workoutDurationChart,
    chartType: .bar,
    onScrollNearStart: { viewModel.sendViewEvent(.loadOlderData) },
    onScrollNearEnd: { viewModel.sendViewEvent(.loadNewerData) }
)
```

Repeat for all 6 chart instances.

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Scrolling near start of data triggers backward pagination callback
- [ ] Scrolling near end of data triggers forward pagination callback
- [ ] Callbacks only fire once per boundary approach (not repeatedly)

---

## Phase 3: Bidirectional Pagination Infrastructure

### Overview
Add events, domain state tracking, and interactor logic for loading data in both directions (older and newer).

### Changes Required:

#### 1. TrendsEvent.swift - Add bidirectional load events
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/TrendsEvent.swift`

```swift
@CasePathable
enum TrendsEvent: Equatable, Sendable {
    case onAppear
    case refresh
    case loadOlderData
    case loadNewerData
}
```

#### 2. TrendsDomainState.swift - Add date range tracking
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/TrendsDomainState.swift`

Update TrendsData to track loaded range and loading direction:
```swift
struct TrendsData: Equatable {
    var dailyWorkoutStats: [DailyWorkoutStats]
    var dailyRecoveryStats: [DailyRecoveryStats]
    let lastUpdated: Date
    var earliestLoadedDate: Date
    var latestLoadedDate: Date
    var isLoadingOlder: Bool
    var isLoadingNewer: Bool
}
```

#### 3. TrendsInteractor.swift - Add bidirectional pagination logic
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/TrendsInteractor.swift`

Update body to handle both pagination directions:
```swift
var body: some InteractorOf<Self> {
    Interact(initialValue: .loading) { state, event in
        switch event {
        case .onAppear, .refresh:
            state = .loading
            return .perform { [healthKitReader] _, send in
                await loadTrendsData(healthKitReader: healthKitReader, send: send)
            }

        case .loadOlderData:
            guard case .loaded(var data) = state, !data.isLoadingOlder else {
                return .state
            }
            data.isLoadingOlder = true
            state = .loaded(data)
            return .perform { [healthKitReader] currentState, send in
                await loadOlderData(
                    healthKitReader: healthKitReader,
                    currentState: currentState,
                    send: send
                )
            }

        case .loadNewerData:
            guard case .loaded(var data) = state, !data.isLoadingNewer else {
                return .state
            }
            // Don't load newer than today
            let today = Calendar.current.startOfDay(for: Date())
            guard data.latestLoadedDate < today else {
                return .state
            }
            data.isLoadingNewer = true
            state = .loaded(data)
            return .perform { [healthKitReader] currentState, send in
                await loadNewerData(
                    healthKitReader: healthKitReader,
                    currentState: currentState,
                    send: send
                )
            }
        }
    }
}
```

Add loadOlderData function:
```swift
@Sendable
private func loadOlderData(
    healthKitReader: HealthKitReader,
    currentState: TrendsDomainState,
    send: Send<TrendsDomainState>
) async {
    guard case .loaded(let existingData) = currentState else { return }

    let calendar = Calendar.current
    let newEndDate = calendar.date(byAdding: .day, value: -1, to: existingData.earliestLoadedDate)!
    let newStartDate = calendar.date(byAdding: .day, value: -14, to: newEndDate)!

    do {
        async let workouts = healthKitReader.queryWorkouts(from: newStartDate, to: newEndDate)
        async let recovery = healthKitReader.queryRecoveryData(from: newStartDate, to: newEndDate)

        let (workoutResults, recoveryResults) = try await (workouts, recovery)

        let newWorkoutStats = aggregateWorkoutsByDay(workoutResults, from: newStartDate, to: newEndDate)
        let newRecoveryStats = aggregateRecoveryByDay(recoveryResults, from: newStartDate, to: newEndDate)

        // Prepend new data, trim from end (remove newest) to maintain 42-day window
        let mergedWorkoutStats = trimFromEnd(newWorkoutStats + existingData.dailyWorkoutStats, maxDays: 42)
        let mergedRecoveryStats = trimFromEnd(newRecoveryStats + existingData.dailyRecoveryStats, maxDays: 42)

        let updatedData = TrendsData(
            dailyWorkoutStats: mergedWorkoutStats,
            dailyRecoveryStats: mergedRecoveryStats,
            lastUpdated: existingData.lastUpdated,
            earliestLoadedDate: mergedWorkoutStats.first?.date ?? existingData.earliestLoadedDate,
            latestLoadedDate: mergedWorkoutStats.last?.date ?? existingData.latestLoadedDate,
            isLoadingOlder: false,
            isLoadingNewer: false
        )
        await send(.loaded(updatedData))
    } catch {
        var data = existingData
        data.isLoadingOlder = false
        await send(.loaded(data))
    }
}
```

Add loadNewerData function:
```swift
@Sendable
private func loadNewerData(
    healthKitReader: HealthKitReader,
    currentState: TrendsDomainState,
    send: Send<TrendsDomainState>
) async {
    guard case .loaded(let existingData) = currentState else { return }

    let calendar = Calendar.current
    let newStartDate = calendar.date(byAdding: .day, value: 1, to: existingData.latestLoadedDate)!
    let today = calendar.startOfDay(for: Date())
    let newEndDate = min(calendar.date(byAdding: .day, value: 14, to: newStartDate)!, today)

    // Don't fetch if we're already at today
    guard newStartDate <= today else {
        var data = existingData
        data.isLoadingNewer = false
        await send(.loaded(data))
        return
    }

    do {
        async let workouts = healthKitReader.queryWorkouts(from: newStartDate, to: newEndDate)
        async let recovery = healthKitReader.queryRecoveryData(from: newStartDate, to: newEndDate)

        let (workoutResults, recoveryResults) = try await (workouts, recovery)

        let newWorkoutStats = aggregateWorkoutsByDay(workoutResults, from: newStartDate, to: newEndDate)
        let newRecoveryStats = aggregateRecoveryByDay(recoveryResults, from: newStartDate, to: newEndDate)

        // Append new data, trim from start (remove oldest) to maintain 42-day window
        let mergedWorkoutStats = trimFromStart(existingData.dailyWorkoutStats + newWorkoutStats, maxDays: 42)
        let mergedRecoveryStats = trimFromStart(existingData.dailyRecoveryStats + newRecoveryStats, maxDays: 42)

        let updatedData = TrendsData(
            dailyWorkoutStats: mergedWorkoutStats,
            dailyRecoveryStats: mergedRecoveryStats,
            lastUpdated: existingData.lastUpdated,
            earliestLoadedDate: mergedWorkoutStats.first?.date ?? existingData.earliestLoadedDate,
            latestLoadedDate: mergedWorkoutStats.last?.date ?? existingData.latestLoadedDate,
            isLoadingOlder: false,
            isLoadingNewer: false
        )
        await send(.loaded(updatedData))
    } catch {
        var data = existingData
        data.isLoadingNewer = false
        await send(.loaded(data))
    }
}
```

Add trim helper functions:
```swift
private func trimFromEnd<T>(_ stats: [T], maxDays: Int) -> [T] {
    guard stats.count > maxDays else { return stats }
    return Array(stats.prefix(maxDays))
}

private func trimFromStart<T>(_ stats: [T], maxDays: Int) -> [T] {
    guard stats.count > maxDays else { return stats }
    return Array(stats.suffix(maxDays))
}
```

Update initial loadTrendsData to set date range:
```swift
let trendsData = TrendsData(
    dailyWorkoutStats: dailyWorkoutStats,
    dailyRecoveryStats: dailyRecoveryStats,
    lastUpdated: Date(),
    earliestLoadedDate: startDate,
    latestLoadedDate: endDate,
    isLoadingOlder: false,
    isLoadingNewer: false
)
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Scrolling left (older) silently loads historical data
- [ ] Scrolling right (newer) reloads recent data if it was trimmed
- [ ] Forward pagination stops at today (doesn't try to load future data)
- [ ] Maximum 42 days of data maintained (rolling window)
- [ ] Multiple scroll-to-boundary events don't cause duplicate loads (isLoadingOlder/isLoadingNewer guards)

---

## Phase 4: Debounce Bidirectional Pagination Triggers

### Overview
Prevent rapid-fire pagination requests when user scrolls quickly near either boundary.

### Changes Required:

#### 1. TrendChartCard.swift - Add bidirectional debounce logic
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/Charts/TrendChartCard.swift`

Add state for debouncing both directions:
```swift
@State private var lastOlderTriggerDate: Date?
@State private var lastNewerTriggerDate: Date?
```

Update checkIfNearBoundary:
```swift
private func checkIfNearBoundary(_ currentPosition: Date) {
    let calendar = Calendar.current

    // Check proximity to earliest date (scroll left/backward in time)
    if let earliestDate = chartData.dataPoints.first?.date {
        let daysFromStart = calendar.dateComponents([.day], from: earliestDate, to: currentPosition).day ?? 0
        if daysFromStart <= 5 {
            // Debounce: only trigger if boundary has changed
            if lastOlderTriggerDate != earliestDate {
                lastOlderTriggerDate = earliestDate
                onScrollNearStart?()
            }
        }
    }

    // Check proximity to latest date (scroll right/forward in time)
    if let latestDate = chartData.dataPoints.last?.date {
        let daysFromEnd = calendar.dateComponents([.day], from: currentPosition, to: latestDate).day ?? 0
        if daysFromEnd <= 5 {
            // Debounce: only trigger if boundary has changed
            if lastNewerTriggerDate != latestDate {
                lastNewerTriggerDate = latestDate
                onScrollNearEnd?()
            }
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Rapid scrolling near left boundary only triggers one backward load request
- [ ] Rapid scrolling near right boundary only triggers one forward load request
- [ ] After new data loads, scrolling further triggers next pagination in that direction

---

## Testing Strategy

### Manual Testing Steps:
1. Launch app and navigate to Trends tab
2. Verify charts show ~14 days initially with most recent on right
3. Scroll left (toward older dates) on any chart
4. Verify X-axis labels remain readable at all positions
5. Continue scrolling until near the oldest data
6. Verify more data loads silently (chart extends further left)
7. Verify total data doesn't exceed 42 days (oldest data trimmed when scrolling left)
8. Now scroll right (toward newer dates) past the trimmed boundary
9. Verify recent data reloads silently when approaching trimmed boundary
10. Verify scrolling right stops at today (can't scroll into future)
11. Tap on a data point while scrolled - verify selection works
12. Pull to refresh - verify data reloads from scratch (resets to initial 21-day window)

### Edge Cases:
- Empty data for certain days (should show gaps, not crash)
- HealthKit query failure during pagination (should fail silently, keep existing data)
- Rapid scrolling back and forth near boundaries
- Scroll far left, then immediately scroll far right - both directions should load correctly
- App returning from background while scrolled far into history

## Performance Considerations

- **Data Limit**: Max 42 days keeps memory usage bounded
- **Prefetch Trigger**: 5-day threshold gives time to load before user reaches boundary
- **Debounce**: Prevents excessive API calls during rapid scrolling
- **Async Loading**: Pagination happens in background, doesn't block UI
- **Independent Loading States**: `isLoadingOlder` and `isLoadingNewer` allow concurrent loads if needed

## References

- Current implementation: `Examples/UnoHealthKit/UnoHealthKit/Views/Charts/TrendChartCard.swift`
- Research: `thoughts/shared/research/2026-01-01-uno-healthkit-app-architecture.md`
- SwiftCharts scrolling APIs: `.chartScrollableAxes`, `.chartXVisibleDomain`, `.chartScrollPosition`

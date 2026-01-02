# Chart Horizontal Scrolling with Window-Based Pagination

## Overview

Add horizontal scrolling with date-aligned snapping and window-based data loading to TrendChartCard in the UnoHealthKit app. Charts snap to 2-week boundaries for a polished feel, with adjacent windows preloaded for seamless scrolling.

## Current State Analysis

**TrendChartCard.swift**:
- Three chart types (bar, line, area) with identical axis configuration
- Uses `.chartXSelection(value: $selectedDate)` for tap selection (must preserve)
- All data points visible simultaneously (no scrolling)

**TrendsInteractor.swift**:
- Hardcoded 21-day lookback
- Single-shot data fetch, no pagination

**TrendsDomainState.swift**:
- Simple data structure with no windowing

### Key Discoveries:
- SwiftCharts iOS 17+ provides `.chartScrollableAxes(.horizontal)` for native scrolling
- `.chartXVisibleDomain(length: TimeInterval)` controls visible window size
- `.chartScrollPosition(x: $scrollPosition)` enables scroll position tracking
- **`.chartScrollTargetBehavior(.valueAligned(...))`** enables snapping to aligned boundaries
- For dates: `.valueAligned(matching: DateComponents(...), majorAlignment: .page)` snaps to calendar units

## Desired End State

After implementation:
1. Each chart shows 14 days (1 window) and snaps to 2-week boundaries
2. Data is organized into discrete 2-week windows
3. Current window + 1 adjacent window always loaded (2 windows = 28 days)
4. At "now" edge: current + previous window
5. When scrolling back: current + previous + next window (3 windows = 42 days max)
6. Smooth snapping behavior makes scrolling feel intentional

### Verification:
- Charts snap cleanly to 2-week boundaries on release
- Scrolling between windows feels smooth with no jumping
- Adjacent data is always ready (no loading delays)
- X-axis shows appropriate labels for visible window

## What We're NOT Doing

- Continuous scroll position tracking (using discrete windows instead)
- Loading indicators (adjacent windows preloaded)
- Synchronized scroll across charts (each independent)
- Arbitrary date range loading (window-based only)

## Implementation Approach

Window-based architecture:
1. Each window = 14 days of data
2. Windows are indexed relative to "now" (window 0 = most recent 14 days)
3. Track `currentWindowIndex` in view state
4. On window change, ensure adjacent windows are loaded
5. Use `.chartScrollTargetBehavior(.valueAligned(...))` for snapping

## Phase 1: Add Date-Aligned Scrolling to Charts

### Overview
Add horizontal scrolling with 2-week snapping to TrendChartCard.

### Changes Required:

#### 1. TrendChartCard.swift
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/Charts/TrendChartCard.swift`

Add constants and state:
```swift
private let visibleDays: TimeInterval = 14 * 24 * 60 * 60 // 14 days in seconds
@State private var scrollPosition: Date = Date()
```

Add to each chart (bar, line, area) after `.chartXSelection(value: $selectedDate)`:
```swift
.chartScrollableAxes(.horizontal)
.chartXVisibleDomain(length: visibleDays)
.chartScrollPosition(x: $scrollPosition)
.chartScrollTargetBehavior(
    .valueAligned(
        matching: DateComponents(day: 1),
        majorAlignment: .page
    )
)
```

Update X-axis configuration:
```swift
.chartXAxis {
    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
        AxisGridLine()
            .foregroundStyle(Color.gray.opacity(0.3))
        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            .foregroundStyle(.gray)
    }
}
```

Initialize scroll position on appear:
```swift
.onAppear {
    if let lastDate = chartData.dataPoints.last?.date {
        scrollPosition = Calendar.current.date(byAdding: .day, value: -7, to: lastDate) ?? lastDate
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Charts scroll horizontally
- [ ] Releasing scroll snaps to day boundaries
- [ ] ~14 days visible at a time
- [ ] Scroll position starts showing recent data

---

## Phase 2: Window-Based Domain State

### Overview
Refactor domain state to use discrete windows instead of arbitrary date ranges.

### Changes Required:

#### 1. TrendsDomainState.swift
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/TrendsDomainState.swift`

```swift
import CasePaths
import Foundation

@CasePathable
enum TrendsDomainState: Equatable {
    case loading
    case loaded(TrendsData)
    case error(String)
}

struct TrendsData: Equatable {
    var windows: [TrendsWindow]
    let lastUpdated: Date
    var loadedWindowIndices: Set<Int>
    var isLoadingWindow: Int?
}

struct TrendsWindow: Equatable, Identifiable {
    let id: Int // Window index (0 = most recent, -1 = previous, etc.)
    let startDate: Date
    let endDate: Date
    var dailyWorkoutStats: [DailyWorkoutStats]
    var dailyRecoveryStats: [DailyRecoveryStats]
}

struct DailyWorkoutStats: Identifiable, Equatable {
    let id: Date
    let date: Date
    let averageDuration: TimeInterval?
    let averageCalories: Double?
    let workoutCount: Int
}

struct DailyRecoveryStats: Identifiable, Equatable {
    let id: Date
    let date: Date
    let averageSleepHours: Double?
    let averageHRV: Double?
    let averageRHR: Double?
    let averageRespiratoryRate: Double?
}
```

#### 2. TrendsEvent.swift
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/TrendsEvent.swift`

```swift
import CasePaths

@CasePathable
enum TrendsEvent: Equatable, Sendable {
    case onAppear
    case refresh
    case windowChanged(currentIndex: Int)
    case loadWindow(index: Int)
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds after state refactoring

---

## Phase 3: Window Loading Logic in Interactor

### Overview
Add logic to load individual windows and manage the window buffer.

### Changes Required:

#### 1. TrendsInteractor.swift
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/TrendsInteractor.swift`

Add window calculation helpers:
```swift
private func windowDateRange(for index: Int) -> (start: Date, end: Date) {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let windowSize = 14 // days

    let endDate = calendar.date(byAdding: .day, value: -(index * windowSize), to: today)!
    let startDate = calendar.date(byAdding: .day, value: -windowSize + 1, to: endDate)!

    return (startDate, endDate)
}
```

Update body to handle window events:
```swift
var body: some InteractorOf<Self> {
    Interact(initialValue: .loading) { state, event in
        switch event {
        case .onAppear, .refresh:
            state = .loading
            return .perform { [healthKitReader] _, send in
                await loadInitialWindows(healthKitReader: healthKitReader, send: send)
            }

        case .windowChanged(let currentIndex):
            guard let data = state[case: \.loaded] else { return .state }

            // Determine which windows we need
            let neededIndices: Set<Int> = currentIndex == 0
                ? [0, -1]  // At "now" edge: current + previous
                : [currentIndex - 1, currentIndex, currentIndex + 1] // Otherwise: prev + current + next

            // Find windows we need to load
            let toLoad = neededIndices.subtracting(data.loadedWindowIndices)

            // Find windows we can unload (keep max 3)
            let toUnload = data.loadedWindowIndices.subtracting(neededIndices)

            if toLoad.isEmpty && toUnload.isEmpty {
                return .state
            }

            // Start loading first missing window
            if let windowToLoad = toLoad.min() {
                state.modify(\.loaded) { $0.isLoadingWindow = windowToLoad }
                return .perform { [healthKitReader, windowToLoad] _, send in
                    await loadWindow(
                        index: windowToLoad,
                        healthKitReader: healthKitReader,
                        send: send
                    )
                }
            }

            // Unload excess windows
            state.modify(\.loaded) { data in
                data.windows.removeAll { toUnload.contains($0.id) }
                data.loadedWindowIndices.subtract(toUnload)
            }
            return .state

        case .loadWindow(let index):
            guard let data = state[case: \.loaded],
                  !data.loadedWindowIndices.contains(index),
                  data.isLoadingWindow == nil else {
                return .state
            }
            state.modify(\.loaded) { $0.isLoadingWindow = index }
            return .perform { [healthKitReader, index] _, send in
                await loadWindow(index: index, healthKitReader: healthKitReader, send: send)
            }
        }
    }
}
```

Add initial load function:
```swift
@Sendable
private func loadInitialWindows(
    healthKitReader: HealthKitReader,
    send: Send<TrendsDomainState>
) async {
    // Load windows 0 and -1 (most recent 28 days)
    let window0 = await loadWindowData(index: 0, healthKitReader: healthKitReader)
    let windowMinus1 = await loadWindowData(index: -1, healthKitReader: healthKitReader)

    guard let w0 = window0, let wM1 = windowMinus1 else {
        await send(.error("Failed to load trends data"))
        return
    }

    let trendsData = TrendsData(
        windows: [w0, wM1],
        lastUpdated: Date(),
        loadedWindowIndices: [0, -1],
        isLoadingWindow: nil
    )
    await send(.loaded(trendsData))
}
```

Add single window load functions:
```swift
@Sendable
private func loadWindow(
    index: Int,
    healthKitReader: HealthKitReader,
    send: Send<TrendsDomainState>
) async {
    guard let window = await loadWindowData(index: index, healthKitReader: healthKitReader) else {
        // Failed to load, clear loading state
        await send(.loaded) // Will need to handle this properly
        return
    }

    // Send event to merge window into state
    // This requires a new event or inline merge
}

private func loadWindowData(
    index: Int,
    healthKitReader: HealthKitReader
) async -> TrendsWindow? {
    let (startDate, endDate) = windowDateRange(for: index)

    do {
        async let workouts = healthKitReader.queryWorkouts(from: startDate, to: endDate)
        async let recovery = healthKitReader.queryRecoveryData(from: startDate, to: endDate)

        let (workoutResults, recoveryResults) = try await (workouts, recovery)

        let dailyWorkoutStats = aggregateWorkoutsByDay(workoutResults, from: startDate, to: endDate)
        let dailyRecoveryStats = aggregateRecoveryByDay(recoveryResults, from: startDate, to: endDate)

        return TrendsWindow(
            id: index,
            startDate: startDate,
            endDate: endDate,
            dailyWorkoutStats: dailyWorkoutStats,
            dailyRecoveryStats: dailyRecoveryStats
        )
    } catch {
        return nil
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds

#### Manual Verification:
- [ ] Initial load fetches windows 0 and -1
- [ ] Scrolling to window -1 triggers load of window -2
- [ ] Maximum 3 windows loaded at any time

---

## Phase 4: ViewStateReducer Flattens Windows

### Overview
Update ViewStateReducer to flatten windows into a single array of chart data points.

### Changes Required:

#### 1. TrendsViewStateReducer.swift
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/TrendsViewStateReducer.swift`

Update to flatten windows:
```swift
case .loaded(let data):
    // Flatten all windows into sorted arrays
    let allWorkoutStats = data.windows
        .flatMap { $0.dailyWorkoutStats }
        .sorted { $0.date < $1.date }

    let allRecoveryStats = data.windows
        .flatMap { $0.dailyRecoveryStats }
        .sorted { $0.date < $1.date }

    let content = TrendsContent(
        lastUpdated: formatLastUpdated(data.lastUpdated),
        workoutDurationChart: buildWorkoutDurationChart(allWorkoutStats),
        caloriesChart: buildCaloriesChart(allWorkoutStats),
        sleepChart: buildSleepChart(allRecoveryStats),
        hrvChart: buildHRVChart(allRecoveryStats),
        rhrChart: buildRHRChart(allRecoveryStats),
        respiratoryRateChart: buildRespiratoryRateChart(allRecoveryStats)
    )
    // ... rest of reducer
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds

#### Manual Verification:
- [ ] Charts display data from all loaded windows seamlessly

---

## Phase 5: Wire Up Window Change Detection

### Overview
Detect when user scrolls to a new window and trigger adjacent window loading.

### Changes Required:

#### 1. TrendChartCard.swift
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/Charts/TrendChartCard.swift`

Add callback for window changes:
```swift
var onWindowChanged: ((Int) -> Void)?
```

Add window index calculation:
```swift
private func windowIndex(for date: Date) -> Int {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let daysDiff = calendar.dateComponents([.day], from: date, to: today).day ?? 0
    return daysDiff / 14 // Each window is 14 days
}
```

Add onChange handler for scroll position:
```swift
.onChange(of: scrollPosition) { _, newPosition in
    let newWindowIndex = windowIndex(for: newPosition)
    onWindowChanged?(newWindowIndex)
}
```

#### 2. TrendsView.swift
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/TrendsView.swift`

Wire up callback:
```swift
TrendChartCard(
    chartData: content.workoutDurationChart,
    chartType: .bar,
    onWindowChanged: { index in
        viewModel.sendViewEvent(.windowChanged(currentIndex: index))
    }
)
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds

#### Manual Verification:
- [ ] Scrolling to a new window triggers windowChanged event
- [ ] Adjacent windows load automatically
- [ ] Scrolling back and forth loads/unloads windows correctly

---

## Testing Strategy

### Manual Testing Steps:
1. Launch app, navigate to Trends tab
2. Verify charts show 14 days with most recent data
3. Scroll left - verify chart snaps to 2-week boundaries
4. Continue scrolling - verify additional windows load seamlessly
5. Verify maximum 3 windows (42 days) loaded at once
6. Scroll back to present - verify window unloading works
7. Tap data points - verify selection still works
8. Pull to refresh - verify full reload

### Edge Cases:
- Scroll rapidly between windows
- Window load fails (network error)
- Very old data (many windows back)

## Performance Considerations

- **Window size**: 14 days keeps memory bounded per window
- **Max windows**: 3 windows (42 days max) limits total memory
- **Preloading**: Adjacent windows ready before user scrolls there
- **Snapping**: Discrete positions simplify state management

## References

- SwiftCharts scrolling: https://swiftwithmajid.com/2023/07/25/mastering-charts-in-swiftui-scrolling/
- Current implementation: `Examples/UnoHealthKit/UnoHealthKit/Views/Charts/TrendChartCard.swift`

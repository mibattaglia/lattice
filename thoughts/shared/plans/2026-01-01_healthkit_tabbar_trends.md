# UnoHealthKit Tab Bar with Trends View Implementation Plan

## Overview

Add a native bottom tab bar to the UnoHealthKit app with two tabs: Timeline (existing view) and Trends (new view with SwiftCharts). The Trends tab will display colorful, bold graphs showing aggregated health metrics: average workout time per day, average calories burned per day, average sleep hours, average HRV, average RHR, and average respiratory rate.

## Current State Analysis

The UnoHealthKit app currently has a single-screen flow:
- `UnoHealthKitApp` creates a `RootViewModel` for HealthKit authorization
- `RootView` handles permission states and shows `TimelineView` when authorized
- `TimelineView` displays workouts and recovery data in a chronological list using `NavigationStack`
- All views follow the Uno Architecture pattern: Event → Interactor → DomainState → ViewStateReducer → ViewState → View

### Key Discoveries:
- `RootView.swift:28` - Currently shows `TimelineView` directly when in `.ready` state
- `TimelineView.swift:4-17` - Creates its own ViewModel, receives `healthKitReader` via init
- `HealthDomainModels.swift:27-42` - `WorkoutDomainModel` contains `duration`, `totalEnergyBurned`
- `HealthDomainModels.swift:140-165` - `RecoveryDomainModel` contains `sleep` and `vitals` data
- SwiftCharts patterns from examples use `Chart`, `BarMark`, `LineMark`, `AreaMark` with gradient styling

## Desired End State

After implementation:
1. When HealthKit permission is granted, users see a tab bar with two tabs: "Timeline" and "Trends"
2. The Timeline tab shows the existing timeline view (unchanged functionality)
3. The Trends tab shows a scrollable view with 6 colorful chart cards:
   - Average Workout Time per Day (green bar chart)
   - Average Calories Burned per Day (orange bar chart)
   - Average Sleep Hours per Day (indigo area chart)
   - Average HRV per Day (green line chart)
   - Average RHR per Day (red line chart)
   - Average Respiratory Rate per Day (cyan line chart)
4. Each chart displays the last 14 days of data
5. The app maintains the dark theme aesthetic

### Verification:
- Build succeeds with no errors: `swift build`
- App launches and shows permission flow
- After granting permission, tab bar appears at bottom
- Timeline tab shows existing timeline functionality
- Trends tab shows all 6 charts with data from HealthKit
- Charts animate on appear and use gradient styling

## What We're NOT Doing

- Not adding chart interactivity (tap to select data points)
- Not adding date range selection for trends
- Not modifying the existing Timeline functionality
- Not adding sharing or export features for trends
- Not implementing real-time updates for trends (snapshot on appear)
- Not adding accessibility chart descriptors (can be added later)

## Implementation Approach

1. **Modify RootView** to show a `TabView` when in `.ready` state instead of just `TimelineView`
2. **Create Trends feature** following Uno Architecture patterns with full Event/Interactor/ViewState/ViewStateReducer stack
3. **Build chart components** as reusable view components with consistent styling
4. **Use HealthKitReader** to query historical data for trend aggregation

---

## Phase 1: Tab Bar Integration

### Overview
Add `TabView` to RootView when permission is granted, with Timeline as the first tab.

### Changes Required:

#### 1. Update RootView to use TabView
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/RootView.swift`
**Changes**: Replace direct `TimelineView` with `TabView` containing Timeline and Trends tabs

```swift
// In RootView body, replace case .ready:
case .ready:
    TabView {
        TimelineView(healthKitReader: healthKitReader)
            .tabItem {
                Label("Timeline", systemImage: "clock.fill")
            }

        TrendsView(healthKitReader: healthKitReader)
            .tabItem {
                Label("Trends", systemImage: "chart.line.uptrend.xyaxis")
            }
    }
    .tint(.white)
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `cd Examples/UnoHealthKit && xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Tab bar appears at bottom when permission is granted
- [ ] Timeline tab shows existing timeline view
- [ ] Trends tab placeholder is visible
- [ ] Tab bar icons and labels are visible

---

## Phase 2: Trends Domain Layer

### Overview
Create the domain layer for Trends: Event, DomainState, and Interactor following Uno Architecture patterns.

### Changes Required:

#### 1. Create Trends Directory Structure
**Directory**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/`

#### 2. Create TrendsEvent
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/TrendsEvent.swift`

```swift
import CasePaths

@CasePathable
enum TrendsEvent: Equatable, Sendable {
    case onAppear
    case refresh
}
```

#### 3. Create TrendsDomainState
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
    let dailyWorkoutStats: [DailyWorkoutStats]
    let dailyRecoveryStats: [DailyRecoveryStats]
    let lastUpdated: Date
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

#### 4. Create TrendsInteractor
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/TrendsInteractor.swift`

```swift
import Foundation
import UnoArchitecture

@Interactor<TrendsDomainState, TrendsEvent>
struct TrendsInteractor: Sendable {
    private let healthKitReader: HealthKitReader

    init(healthKitReader: HealthKitReader) {
        self.healthKitReader = healthKitReader
    }

    var body: some InteractorOf<Self> {
        Interact(initialValue: .loading) { state, event in
            switch event {
            case .onAppear, .refresh:
                state = .loading
                return .perform { [healthKitReader] _, send in
                    await loadTrendsData(healthKitReader: healthKitReader, send: send)
                }
            }
        }
    }

    @Sendable
    private func loadTrendsData(
        healthKitReader: HealthKitReader,
        send: Send<TrendsDomainState>
    ) async {
        do {
            let calendar = Calendar.current
            let endDate = Date()
            let startDate = calendar.date(byAdding: .day, value: -14, to: endDate)!

            async let workouts = healthKitReader.queryWorkouts(from: startDate, to: endDate)
            async let recovery = healthKitReader.queryRecoveryData(from: startDate, to: endDate)

            let (workoutResults, recoveryResults) = try await (workouts, recovery)

            let dailyWorkoutStats = aggregateWorkoutsByDay(workoutResults, from: startDate, to: endDate)
            let dailyRecoveryStats = aggregateRecoveryByDay(recoveryResults, from: startDate, to: endDate)

            let trendsData = TrendsData(
                dailyWorkoutStats: dailyWorkoutStats,
                dailyRecoveryStats: dailyRecoveryStats,
                lastUpdated: Date()
            )
            await send(.loaded(trendsData))
        } catch {
            await send(.error(error.localizedDescription))
        }
    }

    private func aggregateWorkoutsByDay(
        _ workouts: [WorkoutDomainModel],
        from startDate: Date,
        to endDate: Date
    ) -> [DailyWorkoutStats] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: workouts) { workout in
            calendar.startOfDay(for: workout.startDate)
        }

        var results: [DailyWorkoutStats] = []
        var currentDate = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)

        while currentDate <= endDay {
            let dayWorkouts = grouped[currentDate] ?? []
            let stats = DailyWorkoutStats(
                id: currentDate,
                date: currentDate,
                averageDuration: dayWorkouts.isEmpty ? nil : dayWorkouts.map(\.duration).reduce(0, +) / Double(dayWorkouts.count),
                averageCalories: dayWorkouts.isEmpty ? nil : dayWorkouts.compactMap(\.totalEnergyBurned).reduce(0, +) / Double(dayWorkouts.compactMap(\.totalEnergyBurned).count),
                workoutCount: dayWorkouts.count
            )
            results.append(stats)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        return results
    }

    private func aggregateRecoveryByDay(
        _ recoveryData: [RecoveryDomainModel],
        from startDate: Date,
        to endDate: Date
    ) -> [DailyRecoveryStats] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: recoveryData) { recovery in
            calendar.startOfDay(for: recovery.date)
        }

        var results: [DailyRecoveryStats] = []
        var currentDate = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)

        while currentDate <= endDay {
            let dayRecovery = grouped[currentDate] ?? []

            let sleepHours: [Double] = dayRecovery.compactMap { $0.sleep?.totalSleepDuration }.map { $0 / 3600 }
            let hrvValues: [Double] = dayRecovery.compactMap { $0.vitals?.heartRateVariability }
            let rhrValues: [Double] = dayRecovery.compactMap { $0.vitals?.restingHeartRate }
            let respRates: [Double] = dayRecovery.compactMap { $0.vitals?.respiratoryRate }

            let stats = DailyRecoveryStats(
                id: currentDate,
                date: currentDate,
                averageSleepHours: sleepHours.isEmpty ? nil : sleepHours.reduce(0, +) / Double(sleepHours.count),
                averageHRV: hrvValues.isEmpty ? nil : hrvValues.reduce(0, +) / Double(hrvValues.count),
                averageRHR: rhrValues.isEmpty ? nil : rhrValues.reduce(0, +) / Double(rhrValues.count),
                averageRespiratoryRate: respRates.isEmpty ? nil : respRates.reduce(0, +) / Double(respRates.count)
            )
            results.append(stats)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        return results
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `cd Examples/UnoHealthKit && xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] Files created in correct directory structure

---

## Phase 3: Trends Presentation Layer

### Overview
Create the presentation layer: ViewState and ViewStateReducer for Trends.

### Changes Required:

#### 1. Create TrendsViewState
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/TrendsViewState.swift`

```swift
import Foundation
import SwiftUI
import UnoArchitecture

@ObservableState
@CasePathable
@dynamicMemberLookup
enum TrendsViewState: Equatable {
    case loading
    case loaded(TrendsContent)
    case error(TrendsErrorContent)
}

@ObservableState
struct TrendsContent: Equatable {
    var lastUpdated: String
    var workoutDurationChart: ChartData
    var caloriesChart: ChartData
    var sleepChart: ChartData
    var hrvChart: ChartData
    var rhrChart: ChartData
    var respiratoryRateChart: ChartData
}

@ObservableState
struct ChartData: Equatable {
    let title: String
    let subtitle: String
    let color: Color
    let dataPoints: [ChartDataPoint]
    let hasData: Bool
}

struct ChartDataPoint: Identifiable, Equatable {
    let id: Date
    let date: Date
    let value: Double
    let label: String
}

struct TrendsErrorContent: Equatable {
    let message: String
}
```

#### 2. Create TrendsViewStateReducer
**File**: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Trends/TrendsViewStateReducer.swift`

```swift
import Foundation
import SwiftUI
import UnoArchitecture

@ViewStateReducer<TrendsDomainState, TrendsViewState>
struct TrendsViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState, viewState in
            switch domainState {
            case .loading:
                viewState = .loading

            case .loaded(let data):
                let content = TrendsContent(
                    lastUpdated: formatLastUpdated(data.lastUpdated),
                    workoutDurationChart: buildWorkoutDurationChart(data.dailyWorkoutStats),
                    caloriesChart: buildCaloriesChart(data.dailyWorkoutStats),
                    sleepChart: buildSleepChart(data.dailyRecoveryStats),
                    hrvChart: buildHRVChart(data.dailyRecoveryStats),
                    rhrChart: buildRHRChart(data.dailyRecoveryStats),
                    respiratoryRateChart: buildRespiratoryRateChart(data.dailyRecoveryStats)
                )
                viewState = .loaded(content)

            case .error(let message):
                viewState = .error(TrendsErrorContent(message: message))
            }
        }
    }

    private func formatLastUpdated(_ date: Date) -> String {
        "Updated \(date.formatted(.dateTime.hour().minute()))"
    }

    private func buildWorkoutDurationChart(_ stats: [DailyWorkoutStats]) -> ChartData {
        let dataPoints = stats.compactMap { stat -> ChartDataPoint? in
            guard let duration = stat.averageDuration else { return nil }
            let minutes = duration / 60
            return ChartDataPoint(
                id: stat.date,
                date: stat.date,
                value: minutes,
                label: formatDuration(duration)
            )
        }

        let avgMinutes = dataPoints.isEmpty ? 0 : dataPoints.map(\.value).reduce(0, +) / Double(dataPoints.count)

        return ChartData(
            title: "Workout Time",
            subtitle: dataPoints.isEmpty ? "No data" : "\(Int(avgMinutes))m avg",
            color: .green,
            dataPoints: stats.map { stat in
                ChartDataPoint(
                    id: stat.date,
                    date: stat.date,
                    value: (stat.averageDuration ?? 0) / 60,
                    label: stat.averageDuration.map { formatDuration($0) } ?? "—"
                )
            },
            hasData: !dataPoints.isEmpty
        )
    }

    private func buildCaloriesChart(_ stats: [DailyWorkoutStats]) -> ChartData {
        let dataPoints = stats.compactMap { stat -> ChartDataPoint? in
            guard let calories = stat.averageCalories else { return nil }
            return ChartDataPoint(
                id: stat.date,
                date: stat.date,
                value: calories,
                label: "\(Int(calories)) kcal"
            )
        }

        let avgCalories = dataPoints.isEmpty ? 0 : dataPoints.map(\.value).reduce(0, +) / Double(dataPoints.count)

        return ChartData(
            title: "Calories Burned",
            subtitle: dataPoints.isEmpty ? "No data" : "\(Int(avgCalories)) kcal avg",
            color: .orange,
            dataPoints: stats.map { stat in
                ChartDataPoint(
                    id: stat.date,
                    date: stat.date,
                    value: stat.averageCalories ?? 0,
                    label: stat.averageCalories.map { "\(Int($0)) kcal" } ?? "—"
                )
            },
            hasData: !dataPoints.isEmpty
        )
    }

    private func buildSleepChart(_ stats: [DailyRecoveryStats]) -> ChartData {
        let dataPoints = stats.compactMap { stat -> ChartDataPoint? in
            guard let hours = stat.averageSleepHours else { return nil }
            return ChartDataPoint(
                id: stat.date,
                date: stat.date,
                value: hours,
                label: formatHours(hours)
            )
        }

        let avgHours = dataPoints.isEmpty ? 0 : dataPoints.map(\.value).reduce(0, +) / Double(dataPoints.count)

        return ChartData(
            title: "Sleep",
            subtitle: dataPoints.isEmpty ? "No data" : "\(formatHours(avgHours)) avg",
            color: .indigo,
            dataPoints: stats.map { stat in
                ChartDataPoint(
                    id: stat.date,
                    date: stat.date,
                    value: stat.averageSleepHours ?? 0,
                    label: stat.averageSleepHours.map { formatHours($0) } ?? "—"
                )
            },
            hasData: !dataPoints.isEmpty
        )
    }

    private func buildHRVChart(_ stats: [DailyRecoveryStats]) -> ChartData {
        let dataPoints = stats.compactMap { stat -> ChartDataPoint? in
            guard let hrv = stat.averageHRV else { return nil }
            return ChartDataPoint(
                id: stat.date,
                date: stat.date,
                value: hrv,
                label: "\(Int(hrv)) ms"
            )
        }

        let avgHRV = dataPoints.isEmpty ? 0 : dataPoints.map(\.value).reduce(0, +) / Double(dataPoints.count)

        return ChartData(
            title: "Heart Rate Variability",
            subtitle: dataPoints.isEmpty ? "No data" : "\(Int(avgHRV)) ms avg",
            color: .green,
            dataPoints: stats.map { stat in
                ChartDataPoint(
                    id: stat.date,
                    date: stat.date,
                    value: stat.averageHRV ?? 0,
                    label: stat.averageHRV.map { "\(Int($0)) ms" } ?? "—"
                )
            },
            hasData: !dataPoints.isEmpty
        )
    }

    private func buildRHRChart(_ stats: [DailyRecoveryStats]) -> ChartData {
        let dataPoints = stats.compactMap { stat -> ChartDataPoint? in
            guard let rhr = stat.averageRHR else { return nil }
            return ChartDataPoint(
                id: stat.date,
                date: stat.date,
                value: rhr,
                label: "\(Int(rhr)) bpm"
            )
        }

        let avgRHR = dataPoints.isEmpty ? 0 : dataPoints.map(\.value).reduce(0, +) / Double(dataPoints.count)

        return ChartData(
            title: "Resting Heart Rate",
            subtitle: dataPoints.isEmpty ? "No data" : "\(Int(avgRHR)) bpm avg",
            color: .red,
            dataPoints: stats.map { stat in
                ChartDataPoint(
                    id: stat.date,
                    date: stat.date,
                    value: stat.averageRHR ?? 0,
                    label: stat.averageRHR.map { "\(Int($0)) bpm" } ?? "—"
                )
            },
            hasData: !dataPoints.isEmpty
        )
    }

    private func buildRespiratoryRateChart(_ stats: [DailyRecoveryStats]) -> ChartData {
        let dataPoints = stats.compactMap { stat -> ChartDataPoint? in
            guard let rate = stat.averageRespiratoryRate else { return nil }
            return ChartDataPoint(
                id: stat.date,
                date: stat.date,
                value: rate,
                label: String(format: "%.1f br/min", rate)
            )
        }

        let avgRate = dataPoints.isEmpty ? 0 : dataPoints.map(\.value).reduce(0, +) / Double(dataPoints.count)

        return ChartData(
            title: "Respiratory Rate",
            subtitle: dataPoints.isEmpty ? "No data" : String(format: "%.1f br/min avg", avgRate),
            color: .cyan,
            dataPoints: stats.map { stat in
                ChartDataPoint(
                    id: stat.date,
                    date: stat.date,
                    value: stat.averageRespiratoryRate ?? 0,
                    label: stat.averageRespiratoryRate.map { String(format: "%.1f br/min", $0) } ?? "—"
                )
            },
            hasData: !dataPoints.isEmpty
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func formatHours(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(m)m"
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `cd Examples/UnoHealthKit && xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] ViewState and ViewStateReducer compile without errors

---

## Phase 4: Trends View and Chart Components

### Overview
Create the TrendsView and reusable chart card components using SwiftCharts.

### Changes Required:

#### 1. Create TrendChartCard Component
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/Charts/TrendChartCard.swift`

```swift
import SwiftUI
import Charts

struct TrendChartCard: View {
    let chartData: ChartData
    let chartType: ChartType

    enum ChartType {
        case bar
        case line
        case area
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView
            chartView
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6).opacity(0.15))
        )
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chartData.title)
                .font(.headline)
                .foregroundStyle(.white)

            Text(chartData.subtitle)
                .font(.system(.title, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(chartData.color)
        }
    }

    @ViewBuilder
    private var chartView: some View {
        if chartData.hasData {
            switch chartType {
            case .bar:
                barChart
            case .line:
                lineChart
            case .area:
                areaChart
            }
        } else {
            emptyChart
        }
    }

    private var barChart: some View {
        Chart(chartData.dataPoints) { point in
            BarMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(chartData.color.gradient)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(.gray)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel()
                    .foregroundStyle(.gray)
            }
        }
        .frame(height: 180)
    }

    private var lineChart: some View {
        Chart(chartData.dataPoints) { point in
            LineMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(chartData.color)
            .lineStyle(StrokeStyle(lineWidth: 3))
            .interpolationMethod(.catmullRom)

            PointMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(chartData.color)
            .symbolSize(point.value > 0 ? 40 : 0)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(.gray)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel()
                    .foregroundStyle(.gray)
            }
        }
        .frame(height: 180)
    }

    private var areaChart: some View {
        Chart(chartData.dataPoints) { point in
            AreaMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(
                Gradient(colors: [chartData.color, chartData.color.opacity(0.3)])
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(chartData.color)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(.gray)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel()
                    .foregroundStyle(.gray)
            }
        }
        .frame(height: 180)
    }

    private var emptyChart: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundStyle(.gray)
            Text("No data available")
                .font(.subheadline)
                .foregroundStyle(.gray)
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
    }
}
```

#### 2. Create TrendsView
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/TrendsView.swift`

```swift
import SwiftUI
import Charts
import UnoArchitecture

struct TrendsView: View {
    @State private var viewModel: ViewModel<TrendsEvent, TrendsDomainState, TrendsViewState>

    init(healthKitReader: HealthKitReader) {
        _viewModel = State(
            wrappedValue: ViewModel(
                initialValue: TrendsViewState.loading,
                TrendsInteractor(healthKitReader: healthKitReader)
                    .eraseToAnyInteractor(),
                TrendsViewStateReducer()
                    .eraseToAnyReducer()
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.viewState {
                case .loading:
                    loadingView

                case .loaded(let content):
                    trendsContent(content)

                case .error(let error):
                    errorView(error)
                }
            }
            .background(Color.black)
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if case .loaded(let content) = viewModel.viewState {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Text(content.lastUpdated)
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
        .onAppear {
            viewModel.sendViewEvent(.onAppear)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            Text("Loading trends...")
                .font(.subheadline)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func trendsContent(_ content: TrendsContent) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                sectionHeader("Activity")

                TrendChartCard(chartData: content.workoutDurationChart, chartType: .bar)
                TrendChartCard(chartData: content.caloriesChart, chartType: .bar)

                sectionHeader("Recovery")

                TrendChartCard(chartData: content.sleepChart, chartType: .area)

                sectionHeader("Vitals")

                TrendChartCard(chartData: content.hrvChart, chartType: .line)
                TrendChartCard(chartData: content.rhrChart, chartType: .line)
                TrendChartCard(chartData: content.respiratoryRateChart, chartType: .line)
            }
            .padding()
        }
        .background(Color.black)
        .refreshable {
            viewModel.sendViewEvent(.refresh)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func errorView(_ error: TrendsErrorContent) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Unable to Load Trends")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text(error.message)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                viewModel.sendViewEvent(.refresh)
            }
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.white)
            .clipShape(Capsule())
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
```

#### 3. Create Charts Directory
**Directory**: `Examples/UnoHealthKit/UnoHealthKit/Views/Charts/`

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `cd Examples/UnoHealthKit && xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] TrendsView displays loading state initially
- [ ] Charts render with correct colors
- [ ] Charts show "No data" state when appropriate
- [ ] Pull-to-refresh triggers data reload
- [ ] Section headers display correctly

---

## Phase 5: Final Integration and Polish

### Overview
Complete the integration by updating RootView and ensuring all pieces work together.

### Changes Required:

#### 1. Update RootView with TabView
**File**: `Examples/UnoHealthKit/UnoHealthKit/Views/RootView.swift`
**Changes**: Update the `.ready` case to show TabView

Replace the existing `.ready` case handling:

```swift
case .ready:
    TabView {
        TimelineView(healthKitReader: healthKitReader)
            .tabItem {
                Label("Timeline", systemImage: "clock.fill")
            }

        TrendsView(healthKitReader: healthKitReader)
            .tabItem {
                Label("Trends", systemImage: "chart.line.uptrend.xyaxis")
            }
    }
    .tint(.white)
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `cd Examples/UnoHealthKit && xcodebuild -scheme UnoHealthKit -destination 'platform=iOS Simulator,name=iPhone 16' build`

#### Manual Verification:
- [ ] App launches and shows permission flow
- [ ] After granting permission, tab bar appears
- [ ] Both tabs are functional and display data
- [ ] Tab bar icons match the design (clock for Timeline, chart for Trends)
- [ ] Dark theme is consistent across both tabs
- [ ] Charts animate smoothly
- [ ] Pull-to-refresh works on Trends tab

---

## Testing Strategy

### Manual Testing Steps:
1. Launch app on simulator with HealthKit data
2. Grant HealthKit permissions
3. Verify tab bar appears with two tabs
4. Switch between Timeline and Trends tabs
5. Verify Timeline shows existing functionality unchanged
6. Verify Trends shows 6 chart cards:
   - Workout Time (green bar)
   - Calories Burned (orange bar)
   - Sleep (indigo area)
   - HRV (green line)
   - RHR (red line)
   - Respiratory Rate (cyan line)
7. Pull down on Trends to refresh
8. Test with no HealthKit data (should show "No data" states)

---

## File Summary

### New Files to Create:
1. `Architecture/Trends/TrendsEvent.swift`
2. `Architecture/Trends/TrendsDomainState.swift`
3. `Architecture/Trends/TrendsInteractor.swift`
4. `Architecture/Trends/TrendsViewState.swift`
5. `Architecture/Trends/TrendsViewStateReducer.swift`
6. `Views/TrendsView.swift`
7. `Views/Charts/TrendChartCard.swift`

### Files to Modify:
1. `Views/RootView.swift` - Add TabView with Timeline and Trends tabs

---

## References

- Research document: `thoughts/shared/research/2026-01-01-uno-healthkit-app-architecture.md`
- SwiftCharts examples: `/Users/michaelbattaglia/Documents/swift-charts/Swift-Charts-Examples/`
- Existing Timeline patterns: `Examples/UnoHealthKit/UnoHealthKit/Architecture/Timeline/`

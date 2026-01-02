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
                if viewState.is(\.loaded) {
                    viewState.modify(\.loaded) { content in
                        content.lastUpdated = formatLastUpdated(data.lastUpdated)
                        content.workoutDurationChart = buildWorkoutDurationChart(data.dailyWorkoutStats)
                        content.caloriesChart = buildCaloriesChart(data.dailyWorkoutStats)
                        content.sleepChart = buildSleepChart(data.dailyRecoveryStats)
                        content.hrvChart = buildHRVChart(data.dailyRecoveryStats)
                        content.rhrChart = buildRHRChart(data.dailyRecoveryStats)
                        content.respiratoryRateChart = buildRespiratoryRateChart(data.dailyRecoveryStats)
                    }
                } else {
                    viewState = .loaded(TrendsContent(
                        lastUpdated: formatLastUpdated(data.lastUpdated),
                        workoutDurationChart: buildWorkoutDurationChart(data.dailyWorkoutStats),
                        caloriesChart: buildCaloriesChart(data.dailyWorkoutStats),
                        sleepChart: buildSleepChart(data.dailyRecoveryStats),
                        hrvChart: buildHRVChart(data.dailyRecoveryStats),
                        rhrChart: buildRHRChart(data.dailyRecoveryStats),
                        respiratoryRateChart: buildRespiratoryRateChart(data.dailyRecoveryStats)
                    ))
                }

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
            averageValue: dataPoints.isEmpty ? "—" : "\(Int(avgMinutes))m",
            unit: "avg",
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
            averageValue: dataPoints.isEmpty ? "—" : "\(Int(avgCalories)) kcal",
            unit: "avg",
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
            averageValue: dataPoints.isEmpty ? "—" : formatHours(avgHours),
            unit: "avg",
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
            averageValue: dataPoints.isEmpty ? "—" : "\(Int(avgHRV)) ms",
            unit: "avg",
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
            averageValue: dataPoints.isEmpty ? "—" : "\(Int(avgRHR)) bpm",
            unit: "avg",
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
            averageValue: dataPoints.isEmpty ? "—" : String(format: "%.1f br/min", avgRate),
            unit: "avg",
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

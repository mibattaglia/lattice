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
            WorkoutEventItem(
                id: event.id,
                index: event.index,
                duration: formatDuration(event.duration),
                averageSpeed: event.averageSpeed.map { formatSpeed($0) },
                averageHeartRate: event.averageHeartRate.map { "\(Int($0))" },
                averagePower: event.averagePower.map { "\(Int($0))" },
                averageCadence: event.averageCadence.map { "\(Int($0))" }
            )
        }
    }

    private static func formatSpeed(_ metersPerSecond: Double) -> String {
        let mph = metersPerSecond * 2.23694
        return String(format: "%.1f", mph)
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

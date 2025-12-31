import Foundation
import HealthKit

// MARK: - Timeline Entry (Union of Workout or Recovery)

enum TimelineEntry: Identifiable, Equatable, Sendable {
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

struct WorkoutDomainModel: Identifiable, Equatable, Sendable {
    let id: AnyHashable
    let workoutType: HKWorkoutActivityType
    let workoutName: String?
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let totalEnergyBurned: Double?
    let totalDistance: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let averageSpeed: Double?
    let averagePower: Double?
    let averageCadence: Double?
    let events: [WorkoutEvent]
}

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

    var averageHeartRate: Double? {
        switch self {
        case .lap(let lap): return lap.averageHeartRate
        case .segment(let segment): return segment.averageHeartRate
        }
    }

    var averageSpeed: Double? {
        switch self {
        case .lap(let lap): return lap.averageSpeed
        case .segment(let segment): return segment.averageSpeed
        }
    }

    var averagePower: Double? {
        switch self {
        case .lap(let lap): return lap.averagePower
        case .segment(let segment): return segment.averagePower
        }
    }

    var averageCadence: Double? {
        switch self {
        case .lap(let lap): return lap.averageCadence
        case .segment(let segment): return segment.averageCadence
        }
    }
}

struct WorkoutLap: Identifiable, Equatable, Sendable {
    let id: String
    let index: Int
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let averageHeartRate: Double?
    let averageSpeed: Double?
    let averagePower: Double?
    let averageCadence: Double?
}

struct WorkoutSegment: Identifiable, Equatable, Sendable {
    let id: String
    let index: Int
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let averageHeartRate: Double?
    let averageSpeed: Double?
    let averagePower: Double?
    let averageCadence: Double?
}

// MARK: - Recovery Domain Model (Sleep + Vitals grouped by night)

struct RecoveryDomainModel: Identifiable, Equatable, Sendable {
    let id: AnyHashable
    let date: Date
    let sleep: SleepData?
    let vitals: VitalsData?
}

struct SleepData: Equatable, Sendable {
    let startDate: Date
    let endDate: Date
    let totalSleepDuration: TimeInterval
    let stages: SleepStages
}

struct SleepStages: Equatable, Sendable {
    let awake: TimeInterval
    let rem: TimeInterval
    let core: TimeInterval
    let deep: TimeInterval
}

struct VitalsData: Equatable, Sendable {
    let restingHeartRate: Double?
    let heartRateVariability: Double?
    let respiratoryRate: Double?
}

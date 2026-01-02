import CasePaths
import Foundation

@CasePathable
enum TrendsDomainState: Equatable {
    case loading
    case loaded(TrendsData)
    case error(String)
}

struct TrendsData: Equatable {
    let lastUpdated: Date
    var dailyWorkoutStats: [DailyWorkoutStats]
    var dailyRecoveryStats: [DailyRecoveryStats]
}

struct DailyWorkoutStats: Identifiable, Equatable, Sendable {
    let id: Date
    let date: Date
    let averageDuration: TimeInterval?
    let averageCalories: Double?
    let workoutCount: Int
}

struct DailyRecoveryStats: Identifiable, Equatable, Sendable {
    let id: Date
    let date: Date
    let averageSleepHours: Double?
    let averageHRV: Double?
    let averageRHR: Double?
    let averageRespiratoryRate: Double?
}

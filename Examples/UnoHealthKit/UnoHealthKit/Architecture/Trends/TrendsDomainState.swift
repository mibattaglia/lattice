import CasePaths
import Foundation

@CasePathable
enum TrendsDomainState: Equatable {
    case loading
    case loaded(TrendsData)
    case error(String)
}

struct TrendsData: Equatable {
    var dailyWorkoutStats: [DailyWorkoutStats]
    var dailyRecoveryStats: [DailyRecoveryStats]
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

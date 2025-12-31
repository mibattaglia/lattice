import Foundation
import HealthKit

protocol HealthKitReader: Sendable {
    func checkAuthorization() async -> Bool
    func requestAuthorization() async throws -> Bool
    func queryWorkouts(from startDate: Date, to endDate: Date) async throws -> [WorkoutDomainModel]
    func queryRecoveryData(from startDate: Date, to endDate: Date) async throws -> [RecoveryDomainModel]
    func observeUpdates() -> AsyncThrowingStream<HealthKitUpdate, Error>
}

struct HealthKitUpdate: Sendable {
    let addedWorkouts: [WorkoutDomainModel]
    let deletedWorkoutIDs: Set<UUID>
    let recoveryData: [RecoveryDomainModel]
}

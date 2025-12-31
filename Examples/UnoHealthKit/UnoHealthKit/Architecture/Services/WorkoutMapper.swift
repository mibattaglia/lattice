import Foundation
import HealthKit

protocol WorkoutMapper: Sendable {
    func mapWorkouts(_ workouts: [HKWorkout]) async -> [WorkoutDomainModel]
}

extension WorkoutQueryService: WorkoutMapper {
    func mapWorkouts(_ workouts: [HKWorkout]) async -> [WorkoutDomainModel] {
        var models: [WorkoutDomainModel] = []
        for workout in workouts {
            let model = await mapWorkoutToDomainModel(workout)
            models.append(model)
        }
        return models
    }
}

import Foundation
import HealthKit

struct WorkoutUpdate: Sendable {
    let added: [WorkoutDomainModel]
    let deletedIDs: Set<UUID>
}

protocol AnchoredWorkoutReader: Sendable {
    func observeWorkouts(from startDate: Date) -> AsyncThrowingStream<WorkoutUpdate, Error>
}

struct RealAnchoredWorkoutReader: AnchoredWorkoutReader {
    private let healthStore: HKHealthStore
    private let anchorStore: QueryAnchorStore
    private let workoutMapper: WorkoutMapper

    init(
        healthStore: HKHealthStore,
        anchorStore: QueryAnchorStore,
        workoutMapper: WorkoutMapper
    ) {
        self.healthStore = healthStore
        self.anchorStore = anchorStore
        self.workoutMapper = workoutMapper
    }

    func observeWorkouts(from startDate: Date) -> AsyncThrowingStream<WorkoutUpdate, Error> {
        let healthStore = self.healthStore
        let anchorStore = self.anchorStore
        let workoutMapper = self.workoutMapper

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let predicate = HKQuery.predicateForSamples(
                        withStart: startDate,
                        end: nil,
                        options: .strictStartDate
                    )

                    let currentAnchor = await anchorStore.getWorkoutAnchor()

                    let descriptor = HKAnchoredObjectQueryDescriptor(
                        predicates: [.workout(predicate)],
                        anchor: currentAnchor
                    )

                    let results = descriptor.results(for: healthStore)

                    for try await result in results {
                        let hkWorkouts = result.addedSamples
                        let addedWorkouts = await workoutMapper.mapWorkouts(hkWorkouts)
                        let deletedIDs = Set(result.deletedObjects.map { $0.uuid })

                        await anchorStore.setWorkoutAnchor(result.newAnchor)

                        let update = WorkoutUpdate(
                            added: addedWorkouts,
                            deletedIDs: deletedIDs
                        )

                        continuation.yield(update)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

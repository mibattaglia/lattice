import Foundation
import HealthKit

struct RealHealthKitReader: HealthKitReader, @unchecked Sendable {
    private let healthStore: HKHealthStore
    private let workoutService: WorkoutQueryService
    private let recoveryService: RecoveryQueryService
    private let anchoredWorkoutReader: AnchoredWorkoutReader

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        self.workoutService = WorkoutQueryService(healthStore: healthStore)
        self.recoveryService = RecoveryQueryService(healthStore: healthStore)

        let anchorStore = QueryAnchorStore()
        self.anchoredWorkoutReader = RealAnchoredWorkoutReader(
            healthStore: healthStore,
            anchorStore: anchorStore,
            workoutMapper: workoutService
        )
    }

    private static let requiredTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
        HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
        HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
        HKObjectType.quantityType(forIdentifier: .distanceCycling)!,
        HKObjectType.quantityType(forIdentifier: .runningSpeed)!,
        HKObjectType.quantityType(forIdentifier: .cyclingSpeed)!,
        HKObjectType.quantityType(forIdentifier: .runningPower)!,
        HKObjectType.quantityType(forIdentifier: .cyclingPower)!,
        HKObjectType.quantityType(forIdentifier: .cyclingCadence)!,
        HKObjectType.quantityType(forIdentifier: .stepCount)!,
    ]

    // MARK: - Authorization

    func checkAuthorization() async -> Bool {
        for type in Self.requiredTypes {
            let status = healthStore.authorizationStatus(for: type)
            if status == .notDetermined {
                return false
            }
        }
        return true
    }

    func requestAuthorization() async throws -> Bool {
        try await healthStore.requestAuthorization(toShare: [], read: Self.requiredTypes)
        return true
    }

    // MARK: - Queries

    func queryWorkouts(from startDate: Date, to endDate: Date) async throws -> [WorkoutDomainModel] {
        try await workoutService.queryWorkouts(from: startDate, to: endDate)
    }

    func queryRecoveryData(from startDate: Date, to endDate: Date) async throws -> [RecoveryDomainModel] {
        try await recoveryService.queryRecoveryData(from: startDate, to: endDate)
    }

    // MARK: - Observation

    func observeUpdates() -> AsyncThrowingStream<HealthKitUpdate, Error> {
        let recoveryService = self.recoveryService
        let anchoredWorkoutReader = self.anchoredWorkoutReader

        return AsyncThrowingStream { continuation in
            let task = Task {
                let startDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

                do {
                    var isFirstUpdate = true

                    for try await workoutUpdate in anchoredWorkoutReader.observeWorkouts(from: startDate) {
                        let recoveryData: [RecoveryDomainModel]
                        if isFirstUpdate {
                            recoveryData = try await recoveryService.queryRecoveryData(
                                from: startDate,
                                to: Date()
                            )
                            isFirstUpdate = false
                        } else {
                            recoveryData = []
                        }

                        let update = HealthKitUpdate(
                            addedWorkouts: workoutUpdate.added,
                            deletedWorkoutIDs: workoutUpdate.deletedIDs,
                            recoveryData: recoveryData
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

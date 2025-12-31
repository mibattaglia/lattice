import Foundation
import HealthKit

struct WorkoutQueryService: Sendable {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func queryWorkouts(from startDate: Date, to endDate: Date) async throws -> [WorkoutDomainModel] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            healthStore.execute(query)
        }

        var domainModels: [WorkoutDomainModel] = []
        for workout in workouts {
            let model = await mapWorkoutToDomainModel(workout)
            domainModels.append(model)
        }
        return domainModels
    }

    func mapWorkoutToDomainModel(_ workout: HKWorkout) async -> WorkoutDomainModel {
        let allEvents = workout.workoutEvents ?? []

        let relevantEvents = allEvents
            .filter { $0.type == .lap || $0.type == .segment }
            .sorted { $0.dateInterval.start < $1.dateInterval.start }

        var events: [WorkoutEvent] = []
        for (index, hkEvent) in relevantEvents.enumerated() {
            let eventIndex = index + 1
            let id = "\(workout.uuid)-\(eventTypeName(hkEvent.type))-\(eventIndex)"
            let interval = hkEvent.dateInterval

            let eventStats = await queryEventStatistics(
                for: workout,
                in: interval
            )

            switch hkEvent.type {
            case .lap:
                events.append(.lap(WorkoutLap(
                    id: id,
                    index: eventIndex,
                    startDate: interval.start,
                    endDate: interval.end,
                    duration: interval.duration,
                    averageHeartRate: eventStats.heartRate,
                    averageSpeed: eventStats.speed,
                    averagePower: eventStats.power,
                    averageCadence: eventStats.cadence
                )))
            default:
                events.append(.segment(WorkoutSegment(
                    id: id,
                    index: eventIndex,
                    startDate: interval.start,
                    endDate: interval.end,
                    duration: interval.duration,
                    averageHeartRate: eventStats.heartRate,
                    averageSpeed: eventStats.speed,
                    averagePower: eventStats.power,
                    averageCadence: eventStats.cadence
                )))
            }
        }

        let workoutName = workout.metadata?[HKMetadataKeyWorkoutBrandName] as? String

        return WorkoutDomainModel(
            id: workout.uuid,
            workoutType: workout.workoutActivityType,
            workoutName: workoutName,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            totalEnergyBurned: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            totalDistance: totalDistance(for: workout),
            averageHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            maxHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?.maximumQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            averageSpeed: averageSpeed(for: workout),
            averagePower: averagePower(for: workout),
            averageCadence: averageCadence(for: workout),
            events: events
        )
    }

    private struct EventStatistics {
        let heartRate: Double?
        let speed: Double?
        let power: Double?
        let cadence: Double?
    }

    private func queryEventStatistics(for workout: HKWorkout, in interval: DateInterval) async -> EventStatistics {
        async let heartRate = queryAverageStatistic(
            type: .heartRate,
            in: interval,
            unit: HKUnit.count().unitDivided(by: .minute())
        )
        async let speed = querySpeedStatistic(for: workout, in: interval)
        async let power = queryPowerStatistic(for: workout, in: interval)
        async let cadence = queryCadenceStatistic(for: workout, in: interval)

        return await EventStatistics(
            heartRate: heartRate,
            speed: speed,
            power: power,
            cadence: cadence
        )
    }

    private func queryAverageStatistic(type: HKQuantityTypeIdentifier, in interval: DateInterval, unit: HKUnit) async -> Double? {
        let quantityType = HKQuantityType(type)
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, _ in
                let value = statistics?.averageQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            healthStore.execute(query)
        }
    }

    private func queryCumulativeRateStatistic(type: HKQuantityTypeIdentifier, in interval: DateInterval) async -> Double? {
        let quantityType = HKQuantityType(type)
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                guard let sum = statistics?.sumQuantity()?.doubleValue(for: .count()) else {
                    continuation.resume(returning: nil)
                    return
                }
                let durationMinutes = interval.duration / 60.0
                guard durationMinutes > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: sum / durationMinutes)
            }
            healthStore.execute(query)
        }
    }

    private func querySpeedStatistic(for workout: HKWorkout, in interval: DateInterval) async -> Double? {
        let speedTypes: [HKQuantityTypeIdentifier] = [.runningSpeed, .cyclingSpeed]
        let unit = HKUnit.meter().unitDivided(by: .second())

        for type in speedTypes {
            if let speed = await queryAverageStatistic(type: type, in: interval, unit: unit) {
                return speed
            }
        }
        return nil
    }

    private func queryPowerStatistic(for workout: HKWorkout, in interval: DateInterval) async -> Double? {
        let powerTypes: [HKQuantityTypeIdentifier] = [.runningPower, .cyclingPower]

        for type in powerTypes {
            if let power = await queryAverageStatistic(type: type, in: interval, unit: .watt()) {
                return power
            }
        }
        return nil
    }

    private func queryCadenceStatistic(for workout: HKWorkout, in interval: DateInterval) async -> Double? {
        switch workout.workoutActivityType {
        case .running, .walking, .hiking:
            return await queryCumulativeRateStatistic(type: .stepCount, in: interval)
        case .cycling:
            let unit = HKUnit.count().unitDivided(by: .minute())
            return await queryAverageStatistic(type: .cyclingCadence, in: interval, unit: unit)
        case .swimming:
            return await queryCumulativeRateStatistic(type: .swimmingStrokeCount, in: interval)
        default:
            return nil
        }
    }

    private func totalDistance(for workout: HKWorkout) -> Double? {
        if let distance = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meter()) {
            return distance
        }
        if let distance = workout.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()?.doubleValue(for: .meter()) {
            return distance
        }
        if let distance = workout.statistics(for: HKQuantityType(.distanceSwimming))?.sumQuantity()?.doubleValue(for: .meter()) {
            return distance
        }
        return nil
    }

    private func averageSpeed(for workout: HKWorkout) -> Double? {
        let speedTypes: [HKQuantityTypeIdentifier] = [.runningSpeed, .cyclingSpeed]
        for identifier in speedTypes {
            if let speed = workout.statistics(for: HKQuantityType(identifier))?.averageQuantity()?.doubleValue(for: HKUnit.meter().unitDivided(by: .second())) {
                return speed
            }
        }
        return nil
    }

    private func averagePower(for workout: HKWorkout) -> Double? {
        let powerTypes: [HKQuantityTypeIdentifier] = [.runningPower, .cyclingPower]
        for identifier in powerTypes {
            if let power = workout.statistics(for: HKQuantityType(identifier))?.averageQuantity()?.doubleValue(for: .watt()) {
                return power
            }
        }
        return nil
    }

    private func averageCadence(for workout: HKWorkout) -> Double? {
        switch workout.workoutActivityType {
        case .running, .walking, .hiking:
            guard let sum = workout.statistics(for: HKQuantityType(.stepCount))?.sumQuantity()?.doubleValue(for: .count()) else {
                return nil
            }
            let durationMinutes = workout.duration / 60.0
            return durationMinutes > 0 ? sum / durationMinutes : nil
        case .cycling:
            return workout.statistics(for: HKQuantityType(.cyclingCadence))?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
        case .swimming:
            guard let sum = workout.statistics(for: HKQuantityType(.swimmingStrokeCount))?.sumQuantity()?.doubleValue(for: .count()) else {
                return nil
            }
            let durationMinutes = workout.duration / 60.0
            return durationMinutes > 0 ? sum / durationMinutes : nil
        default:
            return nil
        }
    }

    private func eventTypeName(_ type: HKWorkoutEventType) -> String {
        switch type {
        case .pause: return "pause"
        case .resume: return "resume"
        case .lap: return "lap"
        case .marker: return "marker"
        case .segment: return "segment"
        case .motionPaused: return "motionPaused"
        case .motionResumed: return "motionResumed"
        @unknown default: return "unknown(\(type.rawValue))"
        }
    }
}

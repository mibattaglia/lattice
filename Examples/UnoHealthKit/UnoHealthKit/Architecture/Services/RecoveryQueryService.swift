import Foundation
import HealthKit

struct RecoveryQueryService: Sendable {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func queryRecoveryData(from startDate: Date, to endDate: Date) async throws -> [RecoveryDomainModel] {
        async let sleepSamples = querySleepSamples(from: startDate, to: endDate)
        async let vitalsSamples = queryVitalsSamples(from: startDate, to: endDate)

        let (sleep, vitals) = try await (sleepSamples, vitalsSamples)

        return groupRecoveryByDate(sleep: sleep, vitals: vitals, from: startDate, to: endDate)
    }

    // MARK: - Sleep Queries

    private func querySleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Vitals Queries

    private func queryVitalsSamples(from startDate: Date, to endDate: Date) async throws -> VitalsQueryResult {
        async let restingHR = queryQuantitySamples(identifier: .restingHeartRate, from: startDate, to: endDate)
        async let hrv = queryQuantitySamples(identifier: .heartRateVariabilitySDNN, from: startDate, to: endDate)
        async let respRate = queryQuantitySamples(identifier: .respiratoryRate, from: startDate, to: endDate)

        return try await VitalsQueryResult(
            restingHeartRate: restingHR,
            heartRateVariability: hrv,
            respiratoryRate: respRate
        )
    }

    private func queryQuantitySamples(
        identifier: HKQuantityTypeIdentifier,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(identifier),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Grouping

    private func groupRecoveryByDate(
        sleep: [HKCategorySample],
        vitals: VitalsQueryResult,
        from startDate: Date,
        to endDate: Date
    ) -> [RecoveryDomainModel] {
        let calendar = Calendar.current
        var recoveryByDate: [Date: RecoveryDomainModel] = [:]

        let sleepByDate = Dictionary(grouping: sleep) { sample in
            calendar.startOfDay(for: sample.endDate)
        }

        var currentDate = calendar.startOfDay(for: startDate)
        let endOfRange = calendar.startOfDay(for: endDate)

        while currentDate <= endOfRange {
            let sleepSamples = sleepByDate[currentDate] ?? []
            let sleepData = aggregateSleepData(from: sleepSamples)
            let vitalsData = extractVitalsForDate(currentDate, from: vitals)

            if sleepData != nil || vitalsData != nil {
                recoveryByDate[currentDate] = RecoveryDomainModel(
                    id: currentDate,
                    date: currentDate,
                    sleep: sleepData,
                    vitals: vitalsData
                )
            }

            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        return recoveryByDate.values.sorted { $0.date > $1.date }
    }

    private func aggregateSleepData(from samples: [HKCategorySample]) -> SleepData? {
        guard !samples.isEmpty else { return nil }

        let sleepSessions = groupIntoSleepSessions(samples)
        guard let primarySession = findPrimarySleepSession(sleepSessions) else { return nil }

        var awake: TimeInterval = 0
        var rem: TimeInterval = 0
        var core: TimeInterval = 0
        var deep: TimeInterval = 0

        for sample in primarySession {
            let duration = sample.endDate.timeIntervalSince(sample.startDate)

            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .awake:
                awake += duration
            case .asleepREM:
                rem += duration
            case .asleepCore:
                core += duration
            case .asleepDeep:
                deep += duration
            case .asleepUnspecified, .inBed:
                core += duration
            default:
                break
            }
        }

        let totalSleep = rem + core + deep
        guard totalSleep > 0 else { return nil }

        let sessionStart = primarySession.map(\.startDate).min() ?? .distantFuture
        let sessionEnd = primarySession.map(\.endDate).max() ?? .distantPast

        return SleepData(
            startDate: sessionStart,
            endDate: sessionEnd,
            totalSleepDuration: totalSleep,
            stages: SleepStages(awake: awake, rem: rem, core: core, deep: deep)
        )
    }

    private func groupIntoSleepSessions(_ samples: [HKCategorySample]) -> [[HKCategorySample]] {
        let sorted = samples.sorted { $0.startDate < $1.startDate }
        var sessions: [[HKCategorySample]] = []
        var currentSession: [HKCategorySample] = []

        for sample in sorted {
            if let lastSample = currentSession.last {
                let gap = sample.startDate.timeIntervalSince(lastSample.endDate)
                if gap > 30 * 60 {
                    if !currentSession.isEmpty {
                        sessions.append(currentSession)
                    }
                    currentSession = [sample]
                } else {
                    currentSession.append(sample)
                }
            } else {
                currentSession.append(sample)
            }
        }

        if !currentSession.isEmpty {
            sessions.append(currentSession)
        }

        return sessions
    }

    private func findPrimarySleepSession(_ sessions: [[HKCategorySample]]) -> [HKCategorySample]? {
        guard !sessions.isEmpty else { return nil }

        return sessions.max { session1, session2 in
            let duration1 = sessionSleepDuration(session1)
            let duration2 = sessionSleepDuration(session2)
            return duration1 < duration2
        }
    }

    private func sessionSleepDuration(_ samples: [HKCategorySample]) -> TimeInterval {
        samples.reduce(0) { total, sample in
            let sleepValue = HKCategoryValueSleepAnalysis(rawValue: sample.value)
            let isSleep = sleepValue == .asleepREM || sleepValue == .asleepCore ||
                          sleepValue == .asleepDeep || sleepValue == .asleepUnspecified
            return total + (isSleep ? sample.endDate.timeIntervalSince(sample.startDate) : 0)
        }
    }

    private func extractVitalsForDate(_ date: Date, from vitals: VitalsQueryResult) -> VitalsData? {
        let calendar = Calendar.current

        let restingHR = vitals.restingHeartRate
            .first { calendar.isDate($0.startDate, inSameDayAs: date) }?
            .quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))

        let hrv = vitals.heartRateVariability
            .first { calendar.isDate($0.startDate, inSameDayAs: date) }?
            .quantity.doubleValue(for: .secondUnit(with: .milli))

        let respRate = vitals.respiratoryRate
            .first { calendar.isDate($0.startDate, inSameDayAs: date) }?
            .quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))

        guard restingHR != nil || hrv != nil || respRate != nil else { return nil }

        return VitalsData(
            restingHeartRate: restingHR,
            heartRateVariability: hrv,
            respiratoryRate: respRate
        )
    }
}

struct VitalsQueryResult {
    let restingHeartRate: [HKQuantitySample]
    let heartRateVariability: [HKQuantitySample]
    let respiratoryRate: [HKQuantitySample]
}

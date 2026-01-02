import Foundation
import UnoArchitecture

@Interactor<TrendsDomainState, TrendsEvent>
struct TrendsInteractor: Sendable {
    private let healthKitReader: HealthKitReader
    private let daysToLoad = 90

    init(healthKitReader: HealthKitReader) {
        self.healthKitReader = healthKitReader
    }

    var body: some InteractorOf<Self> {
        Interact(initialValue: .loading) { state, event in
            switch event {
            case .onAppear, .refresh:
                state = .loading
                return .perform { [healthKitReader, daysToLoad] _, send in
                    await loadData(healthKitReader: healthKitReader, days: daysToLoad, send: send)
                }
            }
        }
    }

    @Sendable
    private func loadData(
        healthKitReader: HealthKitReader,
        days: Int,
        send: Send<TrendsDomainState>
    ) async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -days + 1, to: today)!

        do {
            async let workouts = healthKitReader.queryWorkouts(from: startDate, to: today)
            async let recovery = healthKitReader.queryRecoveryData(from: startDate, to: today)

            let (workoutResults, recoveryResults) = try await (workouts, recovery)

            let dailyWorkoutStats = aggregateWorkoutsByDay(workoutResults, from: startDate, to: today)
            let dailyRecoveryStats = aggregateRecoveryByDay(recoveryResults, from: startDate, to: today)

            let trendsData = TrendsData(
                lastUpdated: Date(),
                dailyWorkoutStats: dailyWorkoutStats,
                dailyRecoveryStats: dailyRecoveryStats
            )
            await send(.loaded(trendsData))
        } catch {
            await send(.error("Failed to load trends data"))
        }
    }

    private func aggregateWorkoutsByDay(
        _ workouts: [WorkoutDomainModel],
        from startDate: Date,
        to endDate: Date
    ) -> [DailyWorkoutStats] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: workouts) { workout in
            calendar.startOfDay(for: workout.startDate)
        }

        var results: [DailyWorkoutStats] = []
        var currentDate = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)

        while currentDate <= endDay {
            let dayWorkouts = grouped[currentDate] ?? []
            let caloriesValues = dayWorkouts.compactMap(\.totalEnergyBurned)
            let stats = DailyWorkoutStats(
                id: currentDate,
                date: currentDate,
                averageDuration: dayWorkouts.isEmpty ? nil : dayWorkouts.map(\.duration).reduce(0, +) / Double(dayWorkouts.count),
                averageCalories: caloriesValues.isEmpty ? nil : caloriesValues.reduce(0, +) / Double(caloriesValues.count),
                workoutCount: dayWorkouts.count
            )
            results.append(stats)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        return results
    }

    private func aggregateRecoveryByDay(
        _ recoveryData: [RecoveryDomainModel],
        from startDate: Date,
        to endDate: Date
    ) -> [DailyRecoveryStats] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: recoveryData) { recovery in
            calendar.startOfDay(for: recovery.date)
        }

        var results: [DailyRecoveryStats] = []
        var currentDate = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)

        while currentDate <= endDay {
            let dayRecovery = grouped[currentDate] ?? []

            let sleepHours: [Double] = dayRecovery.compactMap { $0.sleep?.totalSleepDuration }.map { $0 / 3600 }
            let hrvValues: [Double] = dayRecovery.compactMap { $0.vitals?.heartRateVariability }
            let rhrValues: [Double] = dayRecovery.compactMap { $0.vitals?.restingHeartRate }
            let respRates: [Double] = dayRecovery.compactMap { $0.vitals?.respiratoryRate }

            let stats = DailyRecoveryStats(
                id: currentDate,
                date: currentDate,
                averageSleepHours: sleepHours.isEmpty ? nil : sleepHours.reduce(0, +) / Double(sleepHours.count),
                averageHRV: hrvValues.isEmpty ? nil : hrvValues.reduce(0, +) / Double(hrvValues.count),
                averageRHR: rhrValues.isEmpty ? nil : rhrValues.reduce(0, +) / Double(rhrValues.count),
                averageRespiratoryRate: respRates.isEmpty ? nil : respRates.reduce(0, +) / Double(respRates.count)
            )
            results.append(stats)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        return results
    }
}

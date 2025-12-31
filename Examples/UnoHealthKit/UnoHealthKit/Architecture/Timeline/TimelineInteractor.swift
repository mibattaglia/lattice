import Foundation
import UnoArchitecture

@Interactor<TimelineDomainState, TimelineEvent>
struct TimelineInteractor: Sendable {
    private let healthKitReader: HealthKitReader

    init(healthKitReader: HealthKitReader) {
        self.healthKitReader = healthKitReader
    }

    var body: some InteractorOf<Self> {
        Interact(initialValue: .loading) { state, event in
            switch event {
            case .onAppear:
                state = .loading
                return .observe { [healthKitReader] currentState, send in
                    await observeHealthKitUpdates(
                        healthKitReader: healthKitReader,
                        currentState: currentState,
                        send: send
                    )
                }

            case .errorOccurred(let message):
                state = .error(message)
                return .state
            }
        }
    }

    @Sendable
    private func observeHealthKitUpdates(
        healthKitReader: HealthKitReader,
        currentState: DynamicState<TimelineDomainState>,
        send: Send<TimelineDomainState>
    ) async {
        do {
            for try await update in healthKitReader.observeUpdates() {
                print("[TimelineInteractor] Update received - workouts: \(update.addedWorkouts.count), deleted: \(update.deletedWorkoutIDs.count), recovery: \(update.recoveryData.count)")

                let existingEntries = await extractExistingEntries(from: currentState)
                let newState = mergeUpdate(update, into: existingEntries)
                await send(newState)
            }
        } catch {
            print("[TimelineInteractor] Error: \(error)")
            await send(.error(error.localizedDescription))
        }
    }

    private func extractExistingEntries(
        from currentState: DynamicState<TimelineDomainState>
    ) async -> [TimelineEntry] {
        let current = await currentState.current
        if case .loaded(let currentData) = current {
            return currentData.entries
        }
        return []
    }

    private func mergeUpdate(
        _ update: HealthKitUpdate,
        into existingEntries: [TimelineEntry]
    ) -> TimelineDomainState {
        let addedWorkoutEntries = update.addedWorkouts.map { TimelineEntry.workout($0) }
        let deletedIDs = Set(update.deletedWorkoutIDs.map { "workout-\($0)" })

        // Remove deleted entries
        var entries = existingEntries.filter { !deletedIDs.contains($0.id) }

        // Add new workout entries (avoiding duplicates)
        let existingIDs = Set(entries.map { $0.id })
        let newWorkoutEntries = addedWorkoutEntries.filter { !existingIDs.contains($0.id) }
        entries.append(contentsOf: newWorkoutEntries)

        // Add/replace recovery entries
        let recoveryEntries = update.recoveryData.map { TimelineEntry.recovery($0) }
        let recoveryIDs = Set(recoveryEntries.map { $0.id })
        entries.removeAll { recoveryIDs.contains($0.id) }
        entries.append(contentsOf: recoveryEntries)

        // Sort by date descending
        entries.sort { $0.date > $1.date }

        return .loaded(TimelineData(entries: entries, lastUpdated: Date()))
    }
}

import Foundation
import HealthKit
import UnoArchitecture

@ViewStateReducer<TimelineDomainState, TimelineViewState>
struct TimelineViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState in
            switch domainState {
            case .loading:
                return .loading

            case .loaded(let data):
                let sections = groupEntriesBySections(data.entries)
                let lastUpdated = formatLastUpdated(data.lastUpdated)
                return .loaded(TimelineListContent(sections: sections, lastUpdated: lastUpdated))

            case .error(let message):
                return .error(ErrorContent(message: message, canRetry: true))
            }
        }
    }

    private func groupEntriesBySections(_ entries: [TimelineEntry]) -> [TimelineSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.date)
        }

        return grouped
            .sorted { $0.key > $1.key }
            .map { date, entries in
                TimelineSection(
                    id: date.ISO8601Format(),
                    title: formatSectionTitle(date),
                    items: entries.map(mapToListItem)
                )
            }
    }

    private func formatSectionTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    private func formatLastUpdated(_ date: Date) -> String {
        "Updated \(date.formatted(.dateTime.hour().minute()))"
    }

    private func mapToListItem(_ entry: TimelineEntry) -> TimelineListItem {
        switch entry {
        case .workout(let workout):
            return .workout(mapWorkout(workout))
        case .recovery(let recovery):
            return .recovery(mapRecovery(recovery))
        }
    }

    private func mapWorkout(_ workout: WorkoutDomainModel) -> WorkoutListItem {
        let lapCount = workout.events.filter {
            if case .lap = $0 { return true }
            return false
        }.count

        let segmentCount = workout.events.filter {
            if case .segment = $0 { return true }
            return false
        }.count

        let activityName = workout.workoutName
            ?? ActivityNameMapper.displayName(for: workout.workoutType)

        return WorkoutListItem(
            id: String(describing: workout.id),
            workoutType: activityName,
            workoutIcon: ActivityNameMapper.icon(for: workout.workoutType),
            startTime: workout.startDate.formatted(.dateTime.hour().minute()),
            duration: formatDuration(workout.duration),
            calories: workout.totalEnergyBurned.map { "\(Int($0)) kcal" },
            distance: workout.totalDistance.map { formatDistance($0) },
            heartRate: workout.averageHeartRate.map { "\(Int($0)) bpm avg" },
            eventSummary: WorkoutEventSummary(lapCount: lapCount, segmentCount: segmentCount),
            detailViewState: WorkoutDetailViewStateFactory.make(from: workout)
        )
    }

    private func mapRecovery(_ recovery: RecoveryDomainModel) -> RecoveryListItem {
        RecoveryListItem(
            id: String(describing: recovery.id),
            totalSleep: recovery.sleep.map { formatDuration($0.totalSleepDuration) },
            sleepStages: recovery.sleep.map { sleep in
                SleepStagesDisplay(
                    awake: formatDuration(sleep.stages.awake),
                    rem: formatDuration(sleep.stages.rem),
                    core: formatDuration(sleep.stages.core),
                    deep: formatDuration(sleep.stages.deep)
                )
            },
            restingHeartRate: recovery.vitals?.restingHeartRate.map { "\(Int($0)) bpm" },
            hrv: recovery.vitals?.heartRateVariability.map { "\(Int($0)) ms" },
            respiratoryRate: recovery.vitals?.respiratoryRate.map { String(format: "%.1f br/min", $0) },
            detailViewState: RecoveryDetailViewStateFactory.make(from: recovery)
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        let miles = meters / 1609.34
        if miles >= 0.1 {
            return String(format: "%.2f mi", miles)
        } else {
            let feet = meters * 3.28084
            return "\(Int(feet)) ft"
        }
    }
}

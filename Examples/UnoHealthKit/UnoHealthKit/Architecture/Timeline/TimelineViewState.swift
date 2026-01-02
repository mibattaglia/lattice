import Foundation
import UnoArchitecture

@ObservableState
@CasePathable
@dynamicMemberLookup
enum TimelineViewState: Equatable {
    case loading
    case loaded(TimelineListContent)
    case error(ErrorContent)
}

@ObservableState
struct TimelineListContent: Equatable {
    var sections: [TimelineSection]
    var lastUpdated: String
}

@ObservableState
struct TimelineSection: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [TimelineListItem]
}

@ObservableState
enum TimelineListItem: Identifiable, Equatable {
    case workout(WorkoutListItem)
    case recovery(RecoveryListItem)

    var id: String {
        switch self {
        case .workout(let item): return item.id
        case .recovery(let item): return item.id
        }
    }
}

@ObservableState
struct WorkoutListItem: Identifiable, Equatable {
    let id: String
    let workoutType: String
    let workoutIcon: String
    let startTime: String
    let duration: String
    let calories: String?
    let distance: String?
    let heartRate: String?
    let eventSummary: WorkoutEventSummary
    let detailViewState: WorkoutDetailViewState
}

struct WorkoutEventSummary: Equatable {
    let lapCount: Int
    let segmentCount: Int

    var displayText: String {
        switch (lapCount, segmentCount) {
        case (0, 0):
            return ""
        case (let laps, 0):
            return "\(laps) \(laps == 1 ? "lap" : "laps")"
        case (0, let segments):
            return "\(segments) \(segments == 1 ? "segment" : "segments")"
        case (let laps, let segments):
            return "\(laps) \(laps == 1 ? "lap" : "laps"), \(segments) \(segments == 1 ? "segment" : "segments")"
        }
    }

    var totalCount: Int {
        lapCount + segmentCount
    }
}

@ObservableState
struct RecoveryListItem: Identifiable, Equatable {
    let id: String
    let totalSleep: String?
    let sleepStages: SleepStagesDisplay?
    let restingHeartRate: String?
    let hrv: String?
    let respiratoryRate: String?
    let detailViewState: RecoveryDetailViewState
}

struct SleepStagesDisplay: Equatable {
    let awake: String
    let rem: String
    let core: String
    let deep: String
}

struct ErrorContent: Equatable {
    let message: String
    let canRetry: Bool
}

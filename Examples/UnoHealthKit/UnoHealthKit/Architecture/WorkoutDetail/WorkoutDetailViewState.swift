import Foundation
import SwiftUI

struct WorkoutDetailViewState: Equatable {
    let header: WorkoutDetailHeader
    let statsGrid: [WorkoutStatCard]
    let events: [WorkoutEventItem]
}

struct WorkoutDetailHeader: Equatable {
    let activityName: String
    let activityIcon: String
    let dateShort: String
    let timeRange: String
    let accentColor: Color
}

struct WorkoutStatCard: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let unit: String
    let color: Color
}

struct WorkoutEventItem: Identifiable, Equatable {
    let id: String
    let index: Int
    let duration: String
    let averageSpeed: String?
    let averageHeartRate: String?
    let averagePower: String?
    let averageCadence: String?
}

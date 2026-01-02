import Foundation
import SwiftUI
import UnoArchitecture

@ObservableState
@CasePathable
@dynamicMemberLookup
enum TrendsViewState: Equatable {
    case loading
    case loaded(TrendsContent)
    case error(TrendsErrorContent)
}

@ObservableState
struct TrendsContent: Equatable {
    var lastUpdated: String
    var workoutDurationChart: ChartData
    var caloriesChart: ChartData
    var sleepChart: ChartData
    var hrvChart: ChartData
    var rhrChart: ChartData
    var respiratoryRateChart: ChartData
}

@ObservableState
struct ChartData: Equatable {
    let title: String
    let averageValue: String
    let unit: String
    let color: Color
    let dataPoints: [ChartDataPoint]
    let hasData: Bool
    let pointsByDay: [Date: ChartDataPoint]

    init(
        title: String,
        averageValue: String,
        unit: String,
        color: Color,
        dataPoints: [ChartDataPoint],
        hasData: Bool
    ) {
        self.title = title
        self.averageValue = averageValue
        self.unit = unit
        self.color = color
        self.dataPoints = dataPoints
        self.hasData = hasData

        let calendar = Calendar.current
        self.pointsByDay = Dictionary(
            dataPoints.map { (calendar.startOfDay(for: $0.date), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

struct ChartDataPoint: Identifiable, Equatable {
    let id: Date
    let date: Date
    let value: Double
    let label: String
}

struct TrendsErrorContent: Equatable {
    let message: String
}

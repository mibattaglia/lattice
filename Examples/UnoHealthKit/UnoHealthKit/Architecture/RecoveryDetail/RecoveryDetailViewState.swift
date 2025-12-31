import Foundation
import SwiftUI

struct RecoveryDetailViewState: Equatable {
    let header: RecoveryDetailHeader
    let sleepSummary: SleepSummaryCard?
    let sleepStages: [SleepStageCard]
    let vitals: [VitalStatCard]
}

struct RecoveryDetailHeader: Equatable {
    let dateShort: String
    let dateFull: String
    let accentColor: Color
}

struct SleepSummaryCard: Equatable {
    let totalSleep: String
    let bedTime: String
    let wakeTime: String
    let timeInBed: String
}

struct SleepStageCard: Identifiable, Equatable {
    let id: String
    let stageName: String
    let duration: String
    let percentage: String
    let color: Color
    let fractionOfTotal: Double
}

struct VitalStatCard: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let unit: String
    let color: Color
    let icon: String
}

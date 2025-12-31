import Foundation
import SwiftUI

enum RecoveryDetailViewStateFactory {
    static func make(from recovery: RecoveryDomainModel) -> RecoveryDetailViewState {
        RecoveryDetailViewState(
            header: makeHeader(from: recovery),
            sleepSummary: makeSleepSummary(from: recovery.sleep),
            sleepStages: makeSleepStages(from: recovery.sleep),
            vitals: makeVitals(from: recovery.vitals)
        )
    }

    private static func makeHeader(from recovery: RecoveryDomainModel) -> RecoveryDetailHeader {
        RecoveryDetailHeader(
            dateShort: recovery.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
            dateFull: recovery.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()),
            accentColor: .indigo
        )
    }

    private static func makeSleepSummary(from sleep: SleepData?) -> SleepSummaryCard? {
        guard let sleep = sleep else { return nil }

        let bedTime = sleep.startDate.formatted(.dateTime.hour().minute())
        let wakeTime = sleep.endDate.formatted(.dateTime.hour().minute())
        let timeInBed = sleep.endDate.timeIntervalSince(sleep.startDate)

        return SleepSummaryCard(
            totalSleep: formatDurationLong(sleep.totalSleepDuration),
            bedTime: bedTime,
            wakeTime: wakeTime,
            timeInBed: formatDurationLong(timeInBed)
        )
    }

    private static func makeSleepStages(from sleep: SleepData?) -> [SleepStageCard] {
        guard let sleep = sleep else { return [] }

        let total = sleep.totalSleepDuration
        guard total > 0 else { return [] }

        return [
            SleepStageCard(
                id: "awake",
                stageName: "Awake",
                duration: formatDurationShort(sleep.stages.awake),
                percentage: formatPercentage(sleep.stages.awake, of: total),
                color: .orange,
                fractionOfTotal: sleep.stages.awake / total
            ),
            SleepStageCard(
                id: "rem",
                stageName: "REM",
                duration: formatDurationShort(sleep.stages.rem),
                percentage: formatPercentage(sleep.stages.rem, of: total),
                color: .cyan,
                fractionOfTotal: sleep.stages.rem / total
            ),
            SleepStageCard(
                id: "core",
                stageName: "Core",
                duration: formatDurationShort(sleep.stages.core),
                percentage: formatPercentage(sleep.stages.core, of: total),
                color: .blue,
                fractionOfTotal: sleep.stages.core / total
            ),
            SleepStageCard(
                id: "deep",
                stageName: "Deep",
                duration: formatDurationShort(sleep.stages.deep),
                percentage: formatPercentage(sleep.stages.deep, of: total),
                color: .indigo,
                fractionOfTotal: sleep.stages.deep / total
            )
        ]
    }

    private static func makeVitals(from vitals: VitalsData?) -> [VitalStatCard] {
        guard let vitals = vitals else { return [] }

        var cards: [VitalStatCard] = []

        if let rhr = vitals.restingHeartRate {
            cards.append(VitalStatCard(
                id: "rhr",
                title: "Resting Heart Rate",
                value: "\(Int(rhr))",
                unit: "bpm",
                color: .red,
                icon: "heart.fill"
            ))
        }

        if let hrv = vitals.heartRateVariability {
            cards.append(VitalStatCard(
                id: "hrv",
                title: "Heart Rate Variability",
                value: "\(Int(hrv))",
                unit: "ms",
                color: .green,
                icon: "waveform.path.ecg"
            ))
        }

        if let respRate = vitals.respiratoryRate {
            cards.append(VitalStatCard(
                id: "respRate",
                title: "Respiratory Rate",
                value: String(format: "%.1f", respRate),
                unit: "br/min",
                color: .cyan,
                icon: "lungs.fill"
            ))
        }

        return cards
    }

    private static func formatDurationLong(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private static func formatDurationShort(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private static func formatPercentage(_ value: TimeInterval, of total: TimeInterval) -> String {
        guard total > 0 else { return "0%" }
        let percentage = (value / total) * 100
        return "\(Int(percentage))%"
    }
}

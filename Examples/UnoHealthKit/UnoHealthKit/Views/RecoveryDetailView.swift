import SwiftUI

struct RecoveryDetailView: View {
    let viewState: RecoveryDetailViewState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                if viewState.sleepSummary != nil {
                    sleepSection
                }
                if !viewState.sleepStages.isEmpty {
                    sleepStagesSection
                }
                if !viewState.vitals.isEmpty {
                    vitalsSection
                }
            }
            .padding()
        }
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(viewState.header.dateShort)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
        }
    }

    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(viewState.header.accentColor)
                    .frame(width: 64, height: 64)

                Image(systemName: "bed.double.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Recovery")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text(viewState.header.dateFull)
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }

            Spacer()
        }
    }

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sleep")
                .font(.title2.bold())
                .foregroundStyle(.white)

            if let summary = viewState.sleepSummary {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total Sleep")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                            Text(summary.totalSleep)
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .foregroundStyle(.indigo)
                        }
                        Spacer()
                    }

                    HStack(spacing: 24) {
                        sleepTimeView(label: "Bedtime", time: summary.bedTime, icon: "moon.fill")
                        sleepTimeView(label: "Wake Up", time: summary.wakeTime, icon: "sun.max.fill")
                        sleepTimeView(label: "In Bed", time: summary.timeInBed, icon: "bed.double.fill")
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.systemGray6).opacity(0.15))
                )
            }
        }
    }

    private func sleepTimeView(label: String, time: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.gray)
            Text(time)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private var sleepStagesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sleep Stages")
                .font(.title2.bold())
                .foregroundStyle(.white)

            VStack(spacing: 12) {
                sleepStagesBar

                VStack(spacing: 0) {
                    ForEach(Array(viewState.sleepStages.enumerated()), id: \.element.id) { index, stage in
                        SleepStageRow(stage: stage)
                        if index < viewState.sleepStages.count - 1 {
                            Divider()
                                .background(Color.gray.opacity(0.3))
                        }
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray6).opacity(0.15))
            )
        }
    }

    private var sleepStagesBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(viewState.sleepStages) { stage in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(stage.color)
                        .frame(width: max(geometry.size.width * stage.fractionOfTotal - 2, 0))
                }
            }
        }
        .frame(height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var vitalsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vitals")
                .font(.title2.bold())
                .foregroundStyle(.white)

            VStack(spacing: 0) {
                ForEach(Array(viewState.vitals.enumerated()), id: \.element.id) { index, vital in
                    VitalRow(vital: vital)
                    if index < viewState.vitals.count - 1 {
                        Divider()
                            .background(Color.gray.opacity(0.3))
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray6).opacity(0.15))
            )
        }
    }
}

private struct SleepStageRow: View {
    let stage: SleepStageCard

    var body: some View {
        HStack {
            Circle()
                .fill(stage.color)
                .frame(width: 12, height: 12)

            Text(stage.stageName)
                .font(.body)
                .foregroundStyle(.white)

            Spacer()

            Text(stage.duration)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(stage.color)

            Text(stage.percentage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.gray)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

private struct VitalRow: View {
    let vital: VitalStatCard

    var body: some View {
        HStack {
            Image(systemName: vital.icon)
                .font(.system(size: 20))
                .foregroundStyle(vital.color)
                .frame(width: 32)

            Text(vital.title)
                .font(.body)
                .foregroundStyle(.white)

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(vital.value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(vital.color)
                Text(vital.unit)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(vital.color)
            }
        }
        .padding(.vertical, 12)
    }
}
